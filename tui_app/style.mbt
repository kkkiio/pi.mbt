// 终端样式(ANSI)与文本对齐小工具。
//
// pi-tui 只负责渲染,不提供主题;这里给出 pim 自己的最小样式集。
// 所有函数都是同步纯函数,供组件的 `render` 调用。

///|
const ESC : String = "\u{1B}"

///|
fn wrap(code : String, text : String) -> String {
  "\{ESC}[\{code}m\{text}\{ESC}[0m"
}

///|
/// 次要信息(灰)。
pub fn dim(text : String) -> String {
  wrap("2", text)
}

///|
pub fn bold(text : String) -> String {
  wrap("1", text)
}

///|
pub fn italic(text : String) -> String {
  wrap("3", text)
}

///|
pub fn red(text : String) -> String {
  wrap("31", text)
}

///|
pub fn green(text : String) -> String {
  wrap("32", text)
}

///|
pub fn yellow(text : String) -> String {
  wrap("33", text)
}

///|
pub fn cyan(text : String) -> String {
  wrap("36", text)
}

///|
pub fn magenta(text : String) -> String {
  wrap("35", text)
}

///|
/// 反色(用于当前行/选中)。
pub fn inverse(text : String) -> String {
  wrap("7", text)
}

///|
/// 右侧补空格到 `width`(按可见宽度计算)。
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
/// 紧凑数字(1234 → "1.2k")。
pub fn format_count(value : Int) -> String {
  if value < 1000 {
    value.to_string()
  } else if value < 1_000_000 {
    let tenths = value / 100
    "\{tenths / 10}.\{tenths % 10}k"
  } else {
    let tenths = value / 100_000
    "\{tenths / 10}.\{tenths % 10}M"
  }
}
