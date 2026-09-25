// 聊天记录内容组件:只负责把消息模型同步渲染成终端行。
//
// 布局、滚动和增量绘制由 pi-tui 负责;这里不在 render 中访问外部状态。

///|
/// 聊天记录中的一项。
enum TranscriptItem {
  User(String)
  Note(String)
  Error(String)
  Assistant(String, String, String?, String?)
  ToolCall(String, String)
  ToolResult(String, String, Bool, Int)
}

///|
/// 聊天记录组件,保存用户、assistant 和工具消息的显示模型。
pub struct Transcript {
  mut items : Array[TranscriptItem]
}

///|
const MAX_ITEMS : Int = 400

///|
const MAX_RETAINED_TEXT_WIDTH : Int = 65_536

///|
/// 创建空的聊天记录。
pub fn Transcript::new() -> Transcript {
  { items: [], }
}

///|
/// 向记录追加一条用户消息。
pub fn Transcript::push_user(self : Transcript, text : String) -> Unit {
  self.push_item(TranscriptItem::User(keep_text(text)))
}

///|
/// 向记录追加一条系统提示或普通信息。
pub fn Transcript::push_note(self : Transcript, text : String) -> Unit {
  self.push_item(TranscriptItem::Note(keep_text(text)))
}

///|
/// 向记录追加一条错误信息。
pub fn Transcript::push_error(self : Transcript, text : String) -> Unit {
  self.push_item(TranscriptItem::Error(keep_text(text)))
}

///|
/// 开始一条新的 assistant 消息。
pub fn Transcript::start_assistant(self : Transcript) -> Unit {
  self.push_item(TranscriptItem::Assistant("", "", None, None))
}

///|
/// 把流式 assistant 文本追加到最后一条 assistant 消息。
pub fn Transcript::append_text(self : Transcript, delta : String) -> Unit {
  let index = self.ensure_assistant()
  match self.items[index] {
    TranscriptItem::Assistant(text, thinking, stop_reason, error_message) =>
      self.items[index] = TranscriptItem::Assistant(
        append_text_bounded(text, delta),
        thinking,
        stop_reason,
        error_message,
      )
    _ => ()
  }
}

///|
/// 把流式 assistant 思考内容追加到最后一条 assistant 消息。
pub fn Transcript::append_thinking(self : Transcript, delta : String) -> Unit {
  let index = self.ensure_assistant()
  match self.items[index] {
    TranscriptItem::Assistant(text, thinking, stop_reason, error_message) =>
      self.items[index] = TranscriptItem::Assistant(
        text,
        append_text_bounded(thinking, delta),
        stop_reason,
        error_message,
      )
    _ => ()
  }
}

///|
/// 完成最后一条 assistant 消息并记录停止原因或错误。
pub fn Transcript::finish_assistant(
  self : Transcript,
  stop_reason : String,
  error_message : String?,
) -> Unit {
  let index = self.ensure_assistant()
  match self.items[index] {
    TranscriptItem::Assistant(text, thinking, _, _) =>
      self.items[index] = TranscriptItem::Assistant(
        text,
        thinking,
        Some(keep_text(stop_reason)),
        error_message.map(fn(message) { keep_text(message) }),
      )
    _ => ()
  }
}

///|
/// 追加一条工具调用记录。
pub fn Transcript::push_tool_call(
  self : Transcript,
  name : String,
  arguments : Json,
) -> Unit {
  self.push_item(
    TranscriptItem::ToolCall(keep_text(name), keep_text(arguments.stringify())),
  )
}

///|
/// 追加一条工具结果记录。
pub fn Transcript::push_tool_result(
  self : Transcript,
  name : String,
  text : String,
  is_error : Bool,
) -> Unit {
  let total_lines = count_lines(text)
  self.push_item(
    TranscriptItem::ToolResult(
      keep_text(name),
      keep_text(text),
      is_error,
      total_lines,
    ),
  )
}

///|
/// 返回当前保留的顶层消息项数量。
pub fn Transcript::item_count(self : Transcript) -> Int {
  self.items.length()
}

///|
/// 实现 pi-tui 的同步内容组件协议。
pub impl Widget for Transcript with fn render(self : Transcript, width : Int) -> Array[
  String,
] {
  let safe_width = if width < 0 { 0 } else { width }
  let lines : Array[String] = []
  for index, item in self.items {
    if index > 0 {
      lines.push("")
    }
    let rendered = render_item(item, safe_width)
    for line in rendered {
      lines.push(line)
    }
  }
  lines
}

///|
pub extend Transcript with Widget::{render, invalidate}

///|
/// 追加项并限制模型大小;保留一条省略提示作为历史边界。
fn Transcript::push_item(self : Transcript, item : TranscriptItem) -> Unit {
  if self.items.length() >= MAX_ITEMS {
    self.items = self.items[2:].to_owned()
    self.items.push(TranscriptItem::Note("… earlier messages omitted"))
  }
  self.items.push(item)
}

///|
/// 找到最后一条 assistant,没有时就创建一条。
fn Transcript::ensure_assistant(self : Transcript) -> Int {
  if self.items.is_empty() {
    self.push_item(TranscriptItem::Assistant("", "", None, None))
  } else {
    let last = self.items.length() - 1
    match self.items[last] {
      TranscriptItem::Assistant(_, _, _, _) => ()
      _ => self.push_item(TranscriptItem::Assistant("", "", None, None))
    }
  }
  self.items.length() - 1
}

///|
/// 把文本按换行符拆成可索引的行数组。
fn split_lines(text : String) -> Array[String] {
  [..text.split("\n").map(line => line.to_owned())]
}

///|
/// 统计文本中的逻辑行数,不为计数额外保留整行数组。
fn count_lines(text : String) -> Int {
  let mut count = 0
  for _ in text.split("\n") {
    count += 1
  }
  count
}

///|
/// 限制单条文本的保留大小,避免流式输出无限增长。
fn keep_text(text : String) -> String {
  if visible_width(text) <= MAX_RETAINED_TEXT_WIDTH {
    text
  } else {
    truncate_to_width(text, MAX_RETAINED_TEXT_WIDTH)
  }
}

///|
/// 有界地合并流式文本;达到上限后保留已有内容。
fn append_text_bounded(current : String, delta : String) -> String {
  let current_width = visible_width(current)
  if current_width >= MAX_RETAINED_TEXT_WIDTH {
    current
  } else {
    let remaining = MAX_RETAINED_TEXT_WIDTH - current_width
    let bounded_delta = truncate_to_width(delta, remaining)
    keep_text(current + bounded_delta)
  }
}

///|
/// 把一项渲染为不超过给定宽度的终端行。
fn render_item(item : TranscriptItem, width : Int) -> Array[String] {
  match item {
    TranscriptItem::User(text) => render_user(text, width)
    TranscriptItem::Note(text) => render_simple(text, width, dim)
    TranscriptItem::Error(text) => render_simple(text, width, red)
    TranscriptItem::Assistant(text, thinking, stop_reason, error_message) =>
      render_assistant(text, thinking, stop_reason, error_message, width)
    TranscriptItem::ToolCall(name, arguments) =>
      render_tool_call(name, arguments, width)
    TranscriptItem::ToolResult(name, text, is_error, total_lines) =>
      render_tool_result(name, text, is_error, total_lines, width)
  }
}

///|
/// 渲染用户消息,首行带 cyan 粗体提示符。
fn render_user(text : String, width : Int) -> Array[String] {
  let content_width = available_width(width, 2)
  let wrapped = wrap_text(text, content_width)
  let lines : Array[String] = []
  if wrapped.is_empty() {
    lines.push(fit_line(cyan(bold("> ")), width))
  } else {
    lines.push(fit_line(cyan(bold("> ")) + wrapped[0], width))
    for index in 1..<wrapped.length() {
      lines.push(fit_line("  " + wrapped[index], width))
    }
  }
  lines
}

///|
/// 渲染 assistant 文本、思考和停止信息。
fn render_assistant(
  text : String,
  thinking : String,
  stop_reason : String?,
  error_message : String?,
  width : Int,
) -> Array[String] {
  let lines : Array[String] = []
  if !thinking.is_empty() {
    let thinking_lines = wrap_text(thinking, available_width(width, 2))
    let shown = if thinking_lines.length() > 6 {
      5
    } else {
      thinking_lines.length()
    }
    for index in 0..<shown {
      lines.push(fit_line(dim(italic("  " + thinking_lines[index])), width))
    }
    if thinking_lines.length() > 6 {
      lines.push(fit_line(dim(italic("  …")), width))
    }
  }
  if !text.is_empty() {
    let text_lines = wrap_text(text, available_width(width, 2))
    for line in text_lines {
      lines.push(fit_line("  " + line, width))
    }
  }
  match stop_reason {
    Some(reason) if is_abnormal_stop(reason) =>
      lines.push(fit_line(dim("  (stopped: " + reason + ")"), width))
    _ => ()
  }
  match error_message {
    Some(message) if !message.is_empty() => {
      let error_lines = wrap_text(message, available_width(width, 2))
      for line in error_lines {
        lines.push(fit_line(red("  " + line), width))
      }
    }
    _ => ()
  }
  lines
}

///|
/// 渲染工具调用及其紧凑 JSON 参数。
fn render_tool_call(
  name : String,
  arguments : String,
  width : Int,
) -> Array[String] {
  let prefix = "  ⚙ " + name + " "
  let argument_width = available_width(width, visible_width(prefix))
  let argument_text = truncate_to_width(arguments, argument_width)
  [fit_line(dim(prefix + argument_text), width)]
}

///|
/// 渲染工具结果头部及最多八行输出。
fn render_tool_result(
  name : String,
  text : String,
  is_error : Bool,
  total_lines : Int,
  width : Int,
) -> Array[String] {
  let lines : Array[String] = []
  let header = "  ↳ " + name
  lines.push(fit_line(if is_error { red(header) } else { dim(header) }, width))
  let result_lines = split_lines(text)
  let shown = if result_lines.length() > 8 { 8 } else { result_lines.length() }
  for index in 0..<shown {
    lines.push(fit_line(dim("    " + result_lines[index]), width))
  }
  if total_lines > 8 {
    lines.push(
      fit_line(
        dim(
          "  … (result truncated, " +
          total_lines.to_string() +
          " lines total)",
        ),
        width,
      ),
    )
  }
  lines
}

///|
/// 渲染一个按行换行并统一着色的简单消息。
fn render_simple(
  text : String,
  width : Int,
  color : (String) -> String,
) -> Array[String] {
  let lines : Array[String] = []
  let wrapped = wrap_text(text, available_width(width, 0))
  for line in wrapped {
    lines.push(fit_line(color(line), width))
  }
  if lines.is_empty() {
    lines.push("")
  }
  lines
}

///|
/// 取得扣除缩进后的可用宽度。
fn available_width(width : Int, indent : Int) -> Int {
  let available = width - indent
  if available < 1 {
    1
  } else {
    available
  }
}

///|
/// 截断最终行,保证 ANSI 文本的可见宽度不超出视窗。
fn fit_line(line : String, width : Int) -> String {
  if width <= 0 {
    ""
  } else {
    truncate_to_width(line, width)
  }
}

///|
/// 判断停止原因是否代表错误或中止。
fn is_abnormal_stop(reason : String) -> Bool {
  reason == "error" ||
  reason == "failed" ||
  reason == "abort" ||
  reason == "aborted" ||
  reason == "cancelled" ||
  reason == "canceled"
}
