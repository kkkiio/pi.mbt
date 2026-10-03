// 运行状态:Braille spinner + 标签。
//
// 状态**嵌入输入框上边框**(见 `StatusLine::render_border` 与 `Editor::set_border_provider`),
// 空闲时不留任何行。

///|
/// 当前运行阶段。
pub enum Phase {
  Idle
  /// 工作态:标签(如 "thinking" / 工具名)。
  Working(String)
  Retrying(Int, Int, Double)
}

///|
/// 状态行状态机(spinner 帧 + 标签)。
pub struct StatusLine {
  theme : Theme
  thinking : String
  mut current : Phase
  mut spinner_index : Int
}

///|
/// 创建一个空闲的状态行。
pub fn StatusLine::new(theme : Theme, thinking? : String = "off") -> StatusLine {
  StatusLine::{ theme, thinking, current: Idle, spinner_index: 0, }
}

///|
/// 将状态切换为空闲。
pub fn StatusLine::set_idle(self : StatusLine) -> Unit {
  self.current = Idle
}

///|
/// 开始显示工作状态。
pub fn StatusLine::set_working(self : StatusLine, label : String) -> Unit {
  self.current = Working(label)
}

///|
pub fn StatusLine::set_retry(
  self : StatusLine,
  attempt : Int,
  max_attempts : Int,
  delay_ms : Int,
) -> Unit {
  self.current = Retrying(
    attempt,
    max_attempts,
    now_ms() + delay_ms.to_double(),
  )
}

///|
/// 前进到下一个 braille 旋转帧。
pub fn StatusLine::tick(self : StatusLine) -> Unit {
  self.spinner_index = (self.spinner_index + 1) % 10
}

///|
/// 当前运行阶段。
pub fn StatusLine::phase(self : StatusLine) -> Phase {
  self.current
}

///|
/// 是否正在工作。
pub fn StatusLine::is_working(self : StatusLine) -> Bool {
  match self.current {
    Idle => false
    Working(_) | Retrying(_, _, _) => true
  }
}

///|
/// 返回指定序号的旋转帧。
fn spinner_frame(index : Int) -> String {
  match index % 10 {
    0 => "⠋"
    1 => "⠙"
    2 => "⠹"
    3 => "⠸"
    4 => "⠼"
    5 => "⠴"
    6 => "⠦"
    7 => "⠧"
    8 => "⠇"
    _ => "⠏"
  }
}

///|
/// 状态文本:`⠋ Working (Esc to interrupt)`。
fn StatusLine::activity_text(self : StatusLine, label : String) -> String {
  self.theme.f_accent(spinner_frame(self.spinner_index)) +
  " " +
  self.theme.f_muted("\{label} (Esc to interrupt)")
}

///|
/// 渲染输入框上边框。空闲时返回 `None`(调用方回退到默认 `─` 边框)。
pub fn StatusLine::render_border(
  self : StatusLine,
  width : Int,
  hidden_lines? : Int = 0,
) -> String? {
  if self.current is Idle {
    return None
  }
  if width <= 0 {
    return Some("")
  }
  let retry = self.current is Retrying(_, _, _)
  let spinner = if retry {
    self.theme.f_warning(spinner_frame(self.spinner_index))
  } else {
    self.theme.f_accent(spinner_frame(self.spinner_index))
  }
  let activity = match self.current {
    Working(label) => self.activity_text(label)
    Retrying(attempt, max_attempts, deadline) => {
      let seconds = retry_seconds(deadline - now_ms())
      spinner +
      " " +
      self.theme.f_muted(
        "Retrying (\{attempt}/\{max_attempts}) in \{seconds}s... (Esc to cancel)",
      )
    }
    Idle => ""
  }
  let border = fn(text : String) {
    self.theme.fg(thinking_role(self.thinking), text)
  }
  let overflow = if hidden_lines > 0 {
    " ↑ \{hidden_lines} more "
  } else {
    ""
  }
  let overflow_width = visible_width(overflow)
  let overflow_start = (width - overflow_width) / 2
  let mut status = truncate_without_ellipsis(
    activity,
    if width > 5 {
      width - 5
    } else {
      1
    },
  )
  if hidden_lines > 0 && overflow_start - (4 + visible_width(status)) < 1 {
    status = spinner
  }
  let used = visible_width(status)
  if hidden_lines > 0 &&
    overflow_width + 2 <= width &&
    overflow_start - (4 + used) >= 1 {
    return Some(
      border("── ") +
      status +
      border(
        " " +
        "─".repeat(overflow_start - 4 - used) +
        overflow +
        "─".repeat(width - overflow_start - overflow_width),
      ),
    )
  }
  if width >= used + 5 {
    return Some(
      border("── ") + status + border(" " + "─".repeat(width - used - 4)),
    )
  }
  let prefix = if width - 1 < 3 { width - 1 } else { 3 }
  Some(
    border("─".repeat(prefix)) +
    spinner +
    border("─".repeat(width - prefix - 1)),
  )
}

///|
extern "js" fn retry_seconds(ms : Double) -> Int = "ms => Math.max(0, Math.ceil(ms / 1000))"

///|
fn truncate_without_ellipsis(text : String, width : Int) -> String {
  ns_get("truncateToWidth").apply([
    Value::cast_from(text),
    Value::cast_from(width),
    Value::cast_from(""),
  ])
}
