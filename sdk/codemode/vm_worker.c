/*
 * vm_worker.c — codemode native target 的 VM 工作线程。
 *
 * 每次执行起一个 pthread,内嵌 QuickJS-NG(与 js target 的 quickjs-wasi
 * 同版本引擎),驱动同一份 prelude.js。脚本可以自旋,所以 VM 不进主线程;
 * 复刻 moonbit-community/sqlite3.mbt internal/ffi/executor.c 的模式:
 *
 * - VM->host:bridge C 函数把与 worker.js 同形的 JSON 消息推进 mutex 队列,
 *   并向 dup 后的 @pipe.pipe() 写端写 1 字节唤醒 MoonBit 侧异步读。
 * - host->VM:工具结果进 condvar 队列;VM 在 job 排空后 cond_wait,拿到
 *   result 后调 prelude 的 settle() 再继续 drain。
 * - stop():置 atomic interrupt flag(JS_SetInterruptHandler 轮询)+
 *   cond broadcast + pthread_join。
 *
 * VM 线程上不执行任何 MoonBit 代码/不做 MoonBit refcount(外部线程约束);
 * 所有 FFI 调用都发生在 MoonBit 主线程。
 */

#include <moonbit.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include "vendor/quickjs/quickjs.h"

/* 对齐 quickjs-wasi 的 MAX_STACK_SIZE(512KB),防止深递归打爆 wasm/native 栈 */
#define PIM_VM_STACK_LIMIT (512 * 1024)
/* 每处理多少个 promise job 轮询一次 interrupt(对齐 vm.js JOBS_PER_POLL) */
#define PIM_VM_JOBS_PER_POLL 50

typedef struct pim_vm_msg {
  struct pim_vm_msg *next;
  size_t len;
  char data[]; /* UTF-8 JSON,带 NUL 便于调试 */
} pim_vm_msg_t;

typedef struct pim_vm_result {
  struct pim_vm_result *next;
  int32_t id;
  int32_t ok;
  size_t len;
  char *payload; /* strdup 的 JSON 文本,可为 NULL */
} pim_vm_result_t;

typedef struct pim_codemode_vm {
  pthread_t thread;
  pthread_mutex_t mutex;
  pthread_cond_t inbound_cond;
  /* VM -> host 出站队列(宿主逐条 drain) */
  pim_vm_msg_t *out_head, *out_tail;
  /* host -> VM 入站结果队列(VM idle 时 cond_wait) */
  pim_vm_result_t *in_head, *in_tail;
  int wake_fd; /* dup 的 pipe 写端,VM 线程退出时关闭 */
  atomic_int interrupted;
  atomic_int finished; /* done/crash 已上报 */
  /* 启动参数,spawn 时从 MoonBit Bytes 复制,线程退出时释放。
   * 长度随行:源里可能含嵌入 NUL(strlen 会截断而不是报语法错) */
  char *code, *prelude, *tools, *globals, *store;
  size_t code_len, prelude_len, tools_len, globals_len, store_len;
  size_t mem_limit; /* 0 表示不设限 */
} pim_codemode_vm_t;

/* ------------------------------------------------------------------ */
/* 出站消息(VM -> host)                                              */
/* ------------------------------------------------------------------ */

/* 出站消息入队 + 写唤醒字节;管道非阻塞,EAGAIN/EBADF 均可忽略
 * (唤醒字节只是 nudge,队列才是事实来源)。 */
static void
vm_out_push(pim_codemode_vm_t *vm, const char *data, size_t len) {
  pim_vm_msg_t *msg = malloc(sizeof(*msg) + len + 1);
  if (!msg) {
    return; /* OOM 丢消息;宿主侧 deadline 会收尾 */
  }
  memcpy(msg->data, data, len);
  msg->data[len] = '\0';
  msg->len = len;
  msg->next = NULL;
  pthread_mutex_lock(&vm->mutex);
  if (vm->out_tail) {
    vm->out_tail->next = msg;
  } else {
    vm->out_head = msg;
  }
  vm->out_tail = msg;
  pthread_mutex_unlock(&vm->mutex);
  int8_t byte = 0;
  (void)write(vm->wake_fd, &byte, 1);
}

/* JSON 字符串转义,供无 JS 上下文可用的 crash 上报 */
static size_t
vm_escape_json_string(char *w, const char *s, size_t cap) {
  char *start = w;
  char *end = w + cap;
  for (const unsigned char *p = (const unsigned char *)s; *p && w < end - 8;
       p++) {
    switch (*p) {
    case '"':  w += snprintf(w, end - w, "\\\""); break;
    case '\\': w += snprintf(w, end - w, "\\\\"); break;
    case '\n': w += snprintf(w, end - w, "\\n"); break;
    case '\r': w += snprintf(w, end - w, "\\r"); break;
    case '\t': w += snprintf(w, end - w, "\\t"); break;
    default:
      if (*p < 0x20) {
        w += snprintf(w, end - w, "\\u%04x", *p);
      } else {
        *w++ = (char)*p;
      }
    }
  }
  return (size_t)(w - start);
}

/* {"type":"crash","message":"..."};VM 内部故障统一走这里 */
static void
vm_post_crash(pim_codemode_vm_t *vm, const char *message) {
  size_t cap = strlen(message) * 2 + 64;
  char *buf = malloc(cap);
  if (!buf) {
    return;
  }
  size_t off = 0;
  off += (size_t)snprintf(buf + off, cap - off,
                          "{\"type\":\"crash\",\"message\":\"");
  off += vm_escape_json_string(buf + off, message, cap - off);
  off += (size_t)snprintf(buf + off, cap - off, "\"}");
  vm_out_push(vm, buf, off);
  free(buf);
  atomic_store(&vm->finished, 1);
}

/* ------------------------------------------------------------------ */
/* JS 侧辅助                                                          */
/* ------------------------------------------------------------------ */

static int
pim_vm_interrupt(JSRuntime *rt, void *opaque) {
  (void)rt;
  pim_codemode_vm_t *vm = opaque;
  return atomic_load(&vm->interrupted);
}

/* 异常值转 "Name: message" 文本(给 crash 消息用;对齐 vm.js
 * crashMessage 的 `${error.name}: ${error.message}`,不带 stack) */
static char *
vm_exception_text(JSContext *ctx, JSValueConst exc) {
  const char *head = JS_ToCString(ctx, exc);
  const char *eff = head && *head ? head : "unknown error";
  char *text = strdup(eff);
  if (head) {
    JS_FreeCString(ctx, head);
  }
  return text;
}

/* eval/编译期失败的 errorJson(对齐 vm.js describeException):
 * {name, message, stack: "<Name>: <message>\n<stack>"},以 JSON 文本返回 */
static char *
vm_describe_exception(JSContext *ctx, JSValueConst exc) {
  JSValue name = JS_GetPropertyStr(ctx, exc, "name");
  JSValue message = JS_GetPropertyStr(ctx, exc, "message");
  JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
  /* 这三个指针要么 NULL 要么 JS 拥有,只 free 非 NULL 的;
   * undefined 属性与 vm.js 一样不产字段/参与 head 为 "undefined" */
  const char *name_s = JS_IsUndefined(name) ? NULL : JS_ToCString(ctx, name);
  const char *msg_s = JS_IsUndefined(message) ? NULL : JS_ToCString(ctx, message);
  const char *stack_s = JS_IsUndefined(stack) ? NULL : JS_ToCString(ctx, stack);
  const char *eff_name = name_s ? name_s : "undefined";
  /* head = message ? `${name}: ${message}` : name */
  size_t head_len =
    msg_s ? strlen(eff_name) + 2 + strlen(msg_s) : strlen(eff_name);
  char *head = malloc(head_len + 1);
  if (head) {
    if (msg_s) {
      snprintf(head, head_len + 1, "%s: %s", eff_name, msg_s);
    } else {
      memcpy(head, eff_name, head_len + 1);
    }
  }
  /* stack.trimEnd() 后接到 head 后面 */
  size_t slen = stack_s ? strlen(stack_s) : 0;
  while (slen > 0 &&
         (stack_s[slen - 1] == ' ' || stack_s[slen - 1] == '\t' ||
          stack_s[slen - 1] == '\n' || stack_s[slen - 1] == '\r')) {
    slen--;
  }
  char *stack_text = NULL;
  if (head) {
    stack_text = malloc(head_len + slen + 2);
    if (stack_text) {
      memcpy(stack_text, head, head_len);
      size_t off = head_len;
      if (slen) {
        stack_text[off++] = '\n';
        memcpy(stack_text + off, stack_s, slen);
        off += slen;
      }
      stack_text[off] = '\0';
    }
  }
  JSValue obj = JS_NewObject(ctx);
  if (name_s) {
    JS_SetPropertyStr(ctx, obj, "name", JS_NewString(ctx, name_s));
  }
  if (msg_s) {
    JS_SetPropertyStr(ctx, obj, "message", JS_NewString(ctx, msg_s));
  }
  if (stack_text) {
    JS_SetPropertyStr(ctx, obj, "stack", JS_NewString(ctx, stack_text));
  }
  JSValue text = JS_JSONStringify(ctx, obj, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(ctx, obj);
  JS_FreeValue(ctx, name);
  JS_FreeValue(ctx, message);
  JS_FreeValue(ctx, stack);
  if (name_s) {
    JS_FreeCString(ctx, name_s);
  }
  if (msg_s) {
    JS_FreeCString(ctx, msg_s);
  }
  if (stack_s) {
    JS_FreeCString(ctx, stack_s);
  }
  free(head);
  free(stack_text);
  if (JS_IsException(text)) {
    return NULL;
  }
  const char *json = JS_ToCString(ctx, text);
  JS_FreeValue(ctx, text);
  if (!json) {
    return NULL;
  }
  char *out = strdup(json);
  JS_FreeCString(ctx, json);
  return out;
}

/* {"type":"done","ok":false,"error":<errorJson 字符串>} */
static void
vm_post_done_error(pim_codemode_vm_t *vm, JSContext *ctx,
                   const char *error_json) {
  JSValue msg = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, msg, "type", JS_NewString(ctx, "done"));
  JS_SetPropertyStr(ctx, msg, "ok", JS_NewBool(ctx, 0));
  JS_SetPropertyStr(ctx, msg, "error", JS_NewString(ctx, error_json));
  JSValue text = JS_JSONStringify(ctx, msg, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(ctx, msg);
  if (!JS_IsException(text)) {
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, text);
    if (s) {
      vm_out_push(vm, s, len);
      JS_FreeCString(ctx, s);
    }
    JS_FreeValue(ctx, text);
  }
  atomic_store(&vm->finished, 1);
}

/* ------------------------------------------------------------------ */
/* bridge:prelude 的唯一宿主函数(对应 vm.js 的 bridge)                  */
/* ------------------------------------------------------------------ */

/* 防御性取参:bridge 的调用方(prelude)固定 4 参,但脚本若拿到
 * 引用乱传参,缺位参数按 undefined 处理而不是读 argv 越界 */
#define PIM_ARG(i) (argc > (i) ? argv[i] : JS_UNDEFINED)

static JSValue
pim_vm_bridge(JSContext *ctx, JSValueConst this_val, int argc,
              JSValueConst *argv) {
  (void)this_val;
  pim_codemode_vm_t *vm = JS_GetContextOpaque(ctx);
  if (!vm || argc < 1) {
    return JS_UNDEFINED;
  }
  const char *kind = JS_ToCString(ctx, argv[0]);
  if (!kind) {
    return JS_EXCEPTION;
  }
  int is_call = !strcmp(kind, "call") || !strcmp(kind, "global");
  int is_output = !strcmp(kind, "output");
  int is_done = !strcmp(kind, "done");
  if (!is_call && !is_output && !is_done) {
    /* 未知 kind 与 vm.js 的 switch 一致:静默忽略 */
    JS_FreeCString(ctx, kind);
    return JS_UNDEFINED;
  }
  JSValue msg = JS_NewObject(ctx);
  if (is_call) {
    /* bridge("call"|"global", id, name, argsJson?) */
    int32_t id = 0;
    JS_ToInt32(ctx, &id, PIM_ARG(1));
    JS_SetPropertyStr(ctx, msg, "type", JS_NewString(ctx, "call"));
    JS_SetPropertyStr(ctx, msg, "id", JS_NewInt32(ctx, id));
    JS_SetPropertyStr(ctx, msg, "target",
                      JS_NewString(ctx, !strcmp(kind, "call") ? "tool"
                                                            : "global"));
    JS_SetPropertyStr(ctx, msg, "name", JS_DupValue(ctx, PIM_ARG(2)));
    if (!JS_IsUndefined(PIM_ARG(3))) {
      JS_SetPropertyStr(ctx, msg, "args", JS_DupValue(ctx, PIM_ARG(3)));
    }
  } else if (is_output) {
    /* bridge("output", kind, data, mimeType?) */
    JSValue item = JS_NewObject(ctx);
    const char *sub = JS_ToCString(ctx, PIM_ARG(1));
    if (sub && !strcmp(sub, "image")) {
      JS_SetPropertyStr(ctx, item, "type", JS_NewString(ctx, "image"));
      JS_SetPropertyStr(ctx, item, "data", JS_DupValue(ctx, PIM_ARG(2)));
      if (!JS_IsUndefined(PIM_ARG(3))) {
        JS_SetPropertyStr(ctx, item, "mimeType", JS_DupValue(ctx, PIM_ARG(3)));
      }
    } else {
      int is_console = sub && !strcmp(sub, "console");
      JS_SetPropertyStr(ctx, item, "type", JS_NewString(ctx, "text"));
      JS_SetPropertyStr(ctx, item, "text", JS_DupValue(ctx, PIM_ARG(2)));
      if (is_console) {
        JS_SetPropertyStr(ctx, item, "console", JS_NewBool(ctx, 1));
      }
    }
    if (sub) {
      JS_FreeCString(ctx, sub);
    }
    JS_SetPropertyStr(ctx, msg, "type", JS_NewString(ctx, "output"));
    JS_SetPropertyStr(ctx, msg, "item", item);
  } else if (is_done) {
    /* bridge("done", ok, payload?, writes?) */
    int ok = JS_ToBool(ctx, PIM_ARG(1));
    JS_SetPropertyStr(ctx, msg, "type", JS_NewString(ctx, "done"));
    JS_SetPropertyStr(ctx, msg, "ok", JS_NewBool(ctx, ok));
    if (ok) {
      if (!JS_IsUndefined(PIM_ARG(2))) {
        JS_SetPropertyStr(ctx, msg, "value", JS_DupValue(ctx, PIM_ARG(2)));
      }
      if (!JS_IsUndefined(PIM_ARG(3))) {
        JS_SetPropertyStr(ctx, msg, "writes", JS_DupValue(ctx, PIM_ARG(3)));
      }
    } else if (!JS_IsUndefined(PIM_ARG(2))) {
      JS_SetPropertyStr(ctx, msg, "error", JS_DupValue(ctx, PIM_ARG(2)));
    }
  }
  JS_FreeCString(ctx, kind);
  JSValue text = JS_JSONStringify(ctx, msg, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(ctx, msg);
  if (!JS_IsException(text)) {
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, text);
    if (s) {
      vm_out_push(vm, s, len);
      JS_FreeCString(ctx, s);
    }
    JS_FreeValue(ctx, text);
  }
  /* done 上报后 VM 不再有工作,wait 循环与未决结果一起收尾 */
  if (is_done) {
    atomic_store(&vm->finished, 1);
  }
  return JS_UNDEFINED;
}

/* ------------------------------------------------------------------ */
/* VM 线程主流程(镜像 vm.js startVm 的非 deterministic 路径)            */
/* ------------------------------------------------------------------ */

/* 排空 pending jobs,随后调 stalled() 让 prelude 报告"永远等不到的 promise" */
static void
vm_drain(JSContext *ctx, pim_codemode_vm_t *vm, JSValue api, JSValue stalled) {
  JSRuntime *rt = JS_GetRuntime(ctx);
  int jobs = 0;
  while (JS_IsJobPending(rt)) {
    JSContext *job_ctx = NULL;
    if (JS_ExecutePendingJob(rt, &job_ctx) < 0) {
      /* 异常属于 job 的 context(这里与 ctx 相同,但按 API 约定取) */
      JSValue exc = JS_GetException(job_ctx ? job_ctx : ctx);
      char *text = vm_exception_text(ctx, exc);
      JS_FreeValue(ctx, exc);
      vm_post_crash(vm, text ? text : "Error: Promise job failed");
      free(text);
      return;
    }
    if (++jobs % PIM_VM_JOBS_PER_POLL == 0 &&
        atomic_load(&vm->interrupted)) {
      vm_post_crash(vm, "Error: Execution interrupted");
      return;
    }
  }
  JSValue ret = JS_Call(ctx, stalled, api, 0, NULL);
  if (JS_IsException(ret)) {
    JSValue exc = JS_GetException(ctx);
    char *text = vm_exception_text(ctx, exc);
    JS_FreeValue(ctx, exc);
    vm_post_crash(vm, text ? text : "Error: stalled check failed");
    free(text);
  }
  JS_FreeValue(ctx, ret);
}

/* 阻塞直到有入站结果或被 interrupted;返回 NULL 表示该退出
 * (finished 只由本线程写,此处无需判断) */
static pim_vm_result_t *
vm_wait_inbound(pim_codemode_vm_t *vm) {
  pthread_mutex_lock(&vm->mutex);
  while (!vm->in_head && !atomic_load(&vm->interrupted)) {
    pthread_cond_wait(&vm->inbound_cond, &vm->mutex);
  }
  pim_vm_result_t *r = vm->in_head;
  if (r) {
    vm->in_head = r->next;
    if (!vm->in_head) {
      vm->in_tail = NULL;
    }
  }
  pthread_mutex_unlock(&vm->mutex);
  return r;
}

static void
vm_free_result(pim_vm_result_t *r) {
  free(r->payload);
  free(r);
}

static void *
pim_vm_main(void *opaque) {
  pim_codemode_vm_t *vm = opaque;
  JSRuntime *rt = NULL;
  JSContext *ctx = NULL;
  JSValue api = JS_UNDEFINED;
  JSValue settle = JS_UNDEFINED;
  JSValue run_fn = JS_UNDEFINED;
  JSValue stalled = JS_UNDEFINED;
  JSValue bridge = JS_UNDEFINED;
  JSValue fn = JS_UNDEFINED;

  rt = JS_NewRuntime();
  if (!rt) {
    vm_post_crash(vm, "Error: quickjs: failed to create runtime");
    goto done;
  }
  if (vm->mem_limit) {
    JS_SetMemoryLimit(rt, vm->mem_limit);
  }
  JS_SetMaxStackSize(rt, PIM_VM_STACK_LIMIT);
  JS_SetInterruptHandler(rt, pim_vm_interrupt, vm);
  ctx = JS_NewContext(rt);
  if (!ctx) {
    vm_post_crash(vm, "Error: quickjs: failed to create context");
    goto done;
  }
  JS_SetContextOpaque(ctx, vm);

  {
    JSValue prelude_fn =
      JS_Eval(ctx, vm->prelude, vm->prelude_len, "codemode-prelude.js",
              JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(prelude_fn)) {
      JSValue exc = JS_GetException(ctx);
      char *text = vm_exception_text(ctx, exc);
      JS_FreeValue(ctx, exc);
      vm_post_crash(vm, text ? text : "Error: quickjs: prelude eval failed");
      free(text);
      goto done;
    }
    bridge = JS_NewCFunction(ctx, pim_vm_bridge, "bridge", 4);
    JSValue args[4] = {
      bridge,
      JS_NewStringLen(ctx, vm->tools, vm->tools_len),
      JS_NewStringLen(ctx, vm->globals, vm->globals_len),
      JS_NewStringLen(ctx, vm->store, vm->store_len),
    };
    api = JS_Call(ctx, prelude_fn, JS_UNDEFINED, 4, args);
    JS_FreeValue(ctx, args[1]);
    JS_FreeValue(ctx, args[2]);
    JS_FreeValue(ctx, args[3]);
    JS_FreeValue(ctx, prelude_fn);
    if (JS_IsException(api)) {
      JSValue exc = JS_GetException(ctx);
      char *text = vm_exception_text(ctx, exc);
      JS_FreeValue(ctx, exc);
      vm_post_crash(vm, text ? text : "Error: quickjs: prelude init failed");
      free(text);
      goto done;
    }
    settle = JS_GetPropertyStr(ctx, api, "settle");
    run_fn = JS_GetPropertyStr(ctx, api, "run");
    stalled = JS_GetPropertyStr(ctx, api, "stalled");
  }

  {
    /* 与 vm.js 相同的包装:async 函数体,顶层 await/return 可用;
     * 前缀与脚本共享首行,行号对齐用户源码。
     * memcpy 拼接而非 snprintf:源码可能含嵌入 NUL */
    const char wrap_pre[] = "(async (tools, console) => {";
    const char wrap_post[] = "\n})";
    size_t src_len =
      sizeof(wrap_pre) - 1 + vm->code_len + sizeof(wrap_post);
    char *src = malloc(src_len);
    if (!src) {
      vm_post_crash(vm, "Error: quickjs: out of memory");
      goto done;
    }
    memcpy(src, wrap_pre, sizeof(wrap_pre) - 1);
    memcpy(src + sizeof(wrap_pre) - 1, vm->code, vm->code_len);
    memcpy(src + sizeof(wrap_pre) - 1 + vm->code_len, wrap_post,
           sizeof(wrap_post));
    fn = JS_Eval(ctx, src, src_len - 1, "codemode.js", JS_EVAL_TYPE_GLOBAL);
    free(src);
    if (JS_IsException(fn)) {
      /* 对应 vm.js evalCode 失败:done(ok:false, describeException) */
      JSValue exc = JS_GetException(ctx);
      char *error_json = vm_describe_exception(ctx, exc);
      JS_FreeValue(ctx, exc);
      vm_post_done_error(vm, ctx,
                         error_json ? error_json
                                    : "{\"name\":\"Error\",\"message\":"
                                      "\"script eval failed\"}");
      free(error_json);
      goto done;
    }
    JSValue ret = JS_Call(ctx, run_fn, api, 1, &fn);
    if (JS_IsException(ret)) {
      /* run() 自身不该抛;脚本错误经 done 消息走。清掉 pending 异常 */
      JS_FreeValue(ctx, JS_GetException(ctx));
    }
    JS_FreeValue(ctx, ret);
    JS_FreeValue(ctx, fn);
    fn = JS_UNDEFINED;
  }

  /* drain → 等宿主结果 → settle → 再 drain,直到 done/crash/interrupt */
  for (;;) {
    vm_drain(ctx, vm, api, stalled);
    if (atomic_load(&vm->finished) || atomic_load(&vm->interrupted)) {
      break;
    }
    pim_vm_result_t *result = vm_wait_inbound(vm);
    if (!result) {
      break;
    }
    JSValue sargs[4] = {
      JS_NewInt32(ctx, result->id),
      JS_NewBool(ctx, result->ok),
      result->payload ? JS_NewStringLen(ctx, result->payload, result->len)
                      : JS_UNDEFINED,
      JS_UNDEFINED,
    };
    JSValue sret = JS_Call(ctx, settle, api, 4, sargs);
    if (JS_IsException(sret)) {
      /* settle 抛错说明 prelude 内部坏了;清掉 pending 异常继续 */
      JS_FreeValue(ctx, JS_GetException(ctx));
    }
    JS_FreeValue(ctx, sret);
    JS_FreeValue(ctx, sargs[2]);
    vm_free_result(result);
  }

done:
  JS_FreeValue(ctx, fn);
  JS_FreeValue(ctx, settle);
  JS_FreeValue(ctx, run_fn);
  JS_FreeValue(ctx, stalled);
  JS_FreeValue(ctx, api);
  JS_FreeValue(ctx, bridge);
  if (ctx) {
    JS_FreeContext(ctx);
  }
  if (rt) {
    JS_FreeRuntime(rt);
  }
  free(vm->code);
  free(vm->prelude);
  free(vm->tools);
  free(vm->globals);
  free(vm->store);
  /* 关闭 dup 的写端:宿主侧 pipe 读端见 EOF,pump 协程随之退出 */
  close(vm->wake_fd);
  return NULL;
}

/* ------------------------------------------------------------------ */
/* FFI(全部在 MoonBit 主线程调用)                                       */
/* ------------------------------------------------------------------ */

static char *
vm_dup_bytes(moonbit_bytes_t bytes, size_t *len_out) {
  int32_t len = Moonbit_array_length(bytes);
  char *out = malloc((size_t)len + 1);
  if (!out) {
    *len_out = 0;
    return NULL;
  }
  memcpy(out, bytes, (size_t)len);
  out[len] = '\0';
  *len_out = (size_t)len;
  return out;
}

static void
pim_sigpipe_ignore(void) {
  /* VM 线程可能在宿主关掉管道后写唤醒字节,SIGPIPE 不该杀进程 */
  signal(SIGPIPE, SIG_IGN);
}

/* 创建 VM 线程;返回 NULL 且 *rescode != 0 表示失败 */
MOONBIT_FFI_EXPORT
void *
pim_codemode_vm_spawn(
  moonbit_bytes_t code,
  moonbit_bytes_t prelude,
  moonbit_bytes_t tools,
  moonbit_bytes_t globals,
  moonbit_bytes_t store,
  int64_t mem_limit,
  int32_t wake_fd,
  int32_t *rescode
) {
  static pthread_once_t sigpipe_once = PTHREAD_ONCE_INIT;
  pthread_once(&sigpipe_once, pim_sigpipe_ignore);
  *rescode = 0;
  pim_codemode_vm_t *vm = calloc(1, sizeof(*vm));
  if (!vm) {
    *rescode = ENOMEM;
    return NULL;
  }
  vm->wake_fd = -1; /* calloc 的 0 是合法 fd,fail 路径只 close >= 0 */
  vm->code = vm_dup_bytes(code, &vm->code_len);
  vm->prelude = vm_dup_bytes(prelude, &vm->prelude_len);
  vm->tools = vm_dup_bytes(tools, &vm->tools_len);
  vm->globals = vm_dup_bytes(globals, &vm->globals_len);
  vm->store = vm_dup_bytes(store, &vm->store_len);
  vm->mem_limit = mem_limit > 0 ? (size_t)mem_limit : 0;
  vm->wake_fd = dup(wake_fd);
  if (vm->wake_fd < 0) {
    *rescode = errno; /* 先取 errno,malloc 可能覆写 */
    goto fail;
  }
  {
    /* 子进程(bash 工具等)不该继承 pipe 写端,否则 VM 退出后读端不见 EOF */
    int flags = fcntl(vm->wake_fd, F_GETFD);
    if (flags >= 0) {
      (void)fcntl(vm->wake_fd, F_SETFD, flags | FD_CLOEXEC);
    }
  }
  if (!vm->code || !vm->prelude || !vm->tools || !vm->globals || !vm->store) {
    *rescode = ENOMEM;
    goto fail;
  }
  int mutex_ok = pthread_mutex_init(&vm->mutex, NULL) == 0;
  int cond_ok =
    mutex_ok && pthread_cond_init(&vm->inbound_cond, NULL) == 0;
  if (!cond_ok) {
    *rescode = EAGAIN;
    if (mutex_ok) {
      pthread_mutex_destroy(&vm->mutex);
    }
    goto fail;
  }
  if (pthread_create(&vm->thread, NULL, pim_vm_main, vm) != 0) {
    *rescode = EAGAIN;
    pthread_cond_destroy(&vm->inbound_cond);
    pthread_mutex_destroy(&vm->mutex);
    goto fail;
  }
  return vm;

fail:
  if (vm->wake_fd >= 0) {
    close(vm->wake_fd);
  }
  free(vm->code);
  free(vm->prelude);
  free(vm->tools);
  free(vm->globals);
  free(vm->store);
  free(vm);
  return NULL;
}

/* 宿主应答一条工具调用结果;payload 为 NULL 表示无载荷(对应 settle 的
 * undefined)。VM 已 finished/interrupted 时丢弃。 */
MOONBIT_FFI_EXPORT
void
pim_codemode_vm_post(
  pim_codemode_vm_t *vm,
  int32_t id,
  int32_t ok,
  moonbit_bytes_t payload,
  int32_t has_payload
) {
  if (!vm) {
    return;
  }
  pim_vm_result_t *r = malloc(sizeof(*r));
  if (!r) {
    return;
  }
  r->id = id;
  r->ok = ok;
  r->next = NULL;
  r->len = 0;
  r->payload = NULL;
  if (has_payload) {
    r->len = (size_t)Moonbit_array_length(payload);
    r->payload = malloc(r->len + 1);
    if (r->payload) {
      memcpy(r->payload, payload, r->len);
      r->payload[r->len] = '\0';
    } else {
      r->len = 0;
    }
  }
  pthread_mutex_lock(&vm->mutex);
  if (atomic_load(&vm->finished) || atomic_load(&vm->interrupted)) {
    pthread_mutex_unlock(&vm->mutex);
    vm_free_result(r);
    return;
  }
  if (vm->in_tail) {
    vm->in_tail->next = r;
  } else {
    vm->in_head = r;
  }
  vm->in_tail = r;
  pthread_cond_signal(&vm->inbound_cond);
  pthread_mutex_unlock(&vm->mutex);
}

/* 弹出一条出站消息;队列空返回零长 Bytes(哨兵:JSON 消息永不为空) */
MOONBIT_FFI_EXPORT
moonbit_bytes_t
pim_codemode_vm_next_message(pim_codemode_vm_t *vm) {
  if (!vm) {
    return moonbit_make_bytes(0, 0);
  }
  pthread_mutex_lock(&vm->mutex);
  pim_vm_msg_t *msg = vm->out_head;
  if (msg) {
    vm->out_head = msg->next;
    if (!vm->out_head) {
      vm->out_tail = NULL;
    }
  }
  pthread_mutex_unlock(&vm->mutex);
  if (!msg) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)msg->len, 0);
  memcpy(bytes, msg->data, msg->len);
  free(msg);
  return bytes;
}

/* stop():置 interrupt,broadcast 唤醒等待中的 VM,join 后释放全部内存。
 * 调用后不得再对 vm 发任何 FFI。 */
MOONBIT_FFI_EXPORT
void
pim_codemode_vm_stop(pim_codemode_vm_t *vm) {
  if (!vm) {
    return;
  }
  atomic_store(&vm->interrupted, 1);
  pthread_mutex_lock(&vm->mutex);
  pthread_cond_broadcast(&vm->inbound_cond);
  pthread_mutex_unlock(&vm->mutex);
  pthread_join(vm->thread, NULL);
  while (vm->out_head) {
    pim_vm_msg_t *next = vm->out_head->next;
    free(vm->out_head);
    vm->out_head = next;
  }
  while (vm->in_head) {
    pim_vm_result_t *next = vm->in_head->next;
    vm_free_result(vm->in_head);
    vm->in_head = next;
  }
  pthread_cond_destroy(&vm->inbound_cond);
  pthread_mutex_destroy(&vm->mutex);
  free(vm);
}
