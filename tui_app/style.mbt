// 终端样式:把主题角色渲染成 ANSI。
//
// 颜色值来自 `theme.mbt`(运行时读 pi 的 theme JSON);这里只负责
// 「角色 → 24-bit truecolor」以及文本属性。与 pi 一致:前景重置 `\e[39m`、
// 背景重置 `\e[49m`(这样外层 dim 不会清掉内层颜色),**不设置全局背景**。
//
// 所有函数都是同步纯函数,供组件的 `render` 调用。

///|
const ESC : String = "\u{1B}"

///|
/// 包裹前景色(24-bit),结束时只重置前景。
extern "js" fn fg_hex(hex : String, text : String) -> String =
  #| (hex, text) => {
  #|   const r = parseInt(hex.slice(1, 3), 16);
  #|   const g = parseInt(hex.slice(3, 5), 16);
  #|   const b = parseInt(hex.slice(5, 7), 16);
  #|   return "\u001b[38;2;" + r + ";" + g + ";" + b + "m" + text + "\u001b[39m";
  #| }

///|
/// 包裹背景色(24-bit),结束时只重置背景。
extern "js" fn bg_hex(hex : String, text : String) -> String =
  #| (hex, text) => {
  #|   const r = parseInt(hex.slice(1, 3), 16);
  #|   const g = parseInt(hex.slice(3, 5), 16);
  #|   const b = parseInt(hex.slice(5, 7), 16);
  #|   return "\u001b[48;2;" + r + ";" + g + ";" + b + "m" + text + "\u001b[49m";
  #| }

// ---- 语义色(方法挂在 `Theme` 上,对齐 pi 的 `theme.fg(...)`/`theme.bg(...)`) ----

///|
pub fn Theme::f_text(self : Theme, text : String) -> String {
  fg_hex(self.colors.text, text)
}

///|
pub fn Theme::f_muted(self : Theme, text : String) -> String {
  fg_hex(self.colors.muted, text)
}

///|
pub fn Theme::f_dim(self : Theme, text : String) -> String {
  fg_hex(self.colors.dim, text)
}

///|
pub fn Theme::f_accent(self : Theme, text : String) -> String {
  fg_hex(self.colors.accent, text)
}

///|
pub fn Theme::f_border(self : Theme, text : String) -> String {
  fg_hex(self.colors.border, text)
}

///|
pub fn Theme::f_border_muted(self : Theme, text : String) -> String {
  fg_hex(self.colors.border_muted, text)
}

///|
pub fn Theme::f_success(self : Theme, text : String) -> String {
  fg_hex(self.colors.success, text)
}

///|
pub fn Theme::f_error(self : Theme, text : String) -> String {
  fg_hex(self.colors.error, text)
}

///|
pub fn Theme::f_warning(self : Theme, text : String) -> String {
  fg_hex(self.colors.warning, text)
}

///|
pub fn Theme::f_thinking(self : Theme, text : String) -> String {
  fg_hex(self.colors.thinking_text, text)
}

///|
pub fn Theme::f_custom_label(self : Theme, text : String) -> String {
  fg_hex(self.colors.custom_message_label, text)
}

///|
pub fn Theme::f_md_link(self : Theme, text : String) -> String {
  fg_hex(self.colors.md_link, text)
}

///|
pub fn Theme::f_md_code(self : Theme, text : String) -> String {
  fg_hex(self.colors.md_code, text)
}

///|
pub fn Theme::f_md_code_block(self : Theme, text : String) -> String {
  fg_hex(self.colors.md_code_block, text)
}

///|
pub fn Theme::f_md_border(self : Theme, text : String) -> String {
  fg_hex(self.colors.md_code_block_border, text)
}

///|
/// bash 模式(命令头 + 边框)。
pub fn Theme::f_bash(self : Theme, text : String) -> String {
  fg_hex(self.colors.bash_mode, text)
}

///|
pub fn Theme::bg_user(self : Theme, text : String) -> String {
  bg_hex(self.colors.user_message_bg, text)
}

///|
pub fn Theme::bg_tool_pending(self : Theme, text : String) -> String {
  bg_hex(self.colors.tool_pending_bg, text)
}

///|
pub fn Theme::bg_tool_success(self : Theme, text : String) -> String {
  bg_hex(self.colors.tool_success_bg, text)
}

///|
pub fn Theme::bg_tool_error(self : Theme, text : String) -> String {
  bg_hex(self.colors.tool_error_bg, text)
}

///|
/// 工具块背景:按「结果有无 / 是否错误」选一个背景色函数
/// (pi `toolPendingBg`/`toolSuccessBg`/`toolErrorBg`)。
pub fn Theme::tool_bg(
  self : Theme,
  result : String?,
  is_error : Bool,
) -> (String) -> String {
  match result {
    None => fn(text) { self.bg_tool_pending(text) }
    Some(_) =>
      if is_error {
        fn(text) { self.bg_tool_error(text) }
      } else {
        fn(text) { self.bg_tool_success(text) }
      }
  }
}

// ---- 文本属性 ----

///|
fn wrap_sgr(code : String, text : String) -> String {
  "\{ESC}[\{code}m\{text}\{ESC}[0m"
}

///|
pub fn bold(text : String) -> String {
  wrap_sgr("1", text)
}

///|
pub fn italic(text : String) -> String {
  wrap_sgr("3", text)
}

///|
pub fn underline(text : String) -> String {
  wrap_sgr("4", text)
}

///|
pub fn inverse(text : String) -> String {
  wrap_sgr("7", text)
}

// ---- 对齐小工具 ----

///|
/// 右侧补空格到 `width`(按可见宽度计算,ANSI 不计入)。
pub fn pad_right(text : String, width : Int) -> String {
  let padding = width - visible_width(text)
  if padding <= 0 {
    text
  } else {
    text + " ".repeat(padding)
  }
}

///|
/// 整行左内边距。
pub fn pad_left(text : String, columns : Int) -> String {
  if columns <= 0 {
    text
  } else {
    " ".repeat(columns) + text
  }
}

///|
/// 一整行背景色块:内容补到 `width` 再套背景色。
pub fn bg_line(hex_bg : (String) -> String, text : String, width : Int) -> String {
  hex_bg(pad_right(text, width))
}

///|
/// 纯背景色的空行。
pub fn bg_blank(hex_bg : (String) -> String, width : Int) -> String {
  hex_bg(" ".repeat(if width > 0 { width } else { 0 }))
}

///|
/// 相对时间(毫秒 → "3s" / "1m20s")。
pub fn format_elapsed(milliseconds : Int) -> String {
  let seconds = milliseconds / 1000
  if seconds < 60 {
    "\{seconds}s"
  } else {
    let minutes = seconds / 60
    let rest = seconds % 60
    if rest == 0 {
      "\{minutes}m"
    } else {
      "\{minutes}m\{rest}s"
    }
  }
}

///|
/// 紧凑数字,对齐 pi `formatTokens`:
/// <1k 原样、<10k 一位小数 k、<1M 整数 k、<10M 一位小数 M、否则整数 M。
pub fn format_count(value : Int) -> String {
  if value < 1000 {
    value.to_string()
  } else if value < 10000 {
    let tenths = value / 100
    "\{tenths / 10}.\{tenths % 10}k"
  } else if value < 1000000 {
    "\{(value + 500) / 1000}k"
  } else if value < 10000000 {
    let tenths = value / 100000
    "\{tenths / 10}.\{tenths % 10}M"
  } else {
    "\{(value + 500000) / 1000000}M"
  }
}
