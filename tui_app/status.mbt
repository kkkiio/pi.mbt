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
}

///|
/// 状态行状态机(spinner 帧 + 标签)。
pub struct StatusLine {
  theme : Theme
  mut current : Phase
  mut spinner_index : Int
}

///|
/// 创建一个空闲的状态行。
pub fn StatusLine::new(theme : Theme) -> StatusLine {
  StatusLine::{ theme, current: Idle, spinner_index: 0, }
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
    Working(_) => true
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
  self.theme.f_accent(bold("\{spinner_frame(self.spinner_index)} \{label}")) +
  " " +
  self.theme.f_dim("(Esc to interrupt)")
}

///|
/// 渲染输入框上边框。空闲时返回 `None`(调用方回退到默认 `─` 边框)。
pub fn StatusLine::render_border(self : StatusLine, width : Int) -> String? {
  match self.current {
    Idle => None
    Working(label) => {
      if width <= 0 {
        return Some("")
      }
      let activity = self.activity_text(label)
      let activity_width = visible_width(activity)
      let used = 3 + activity_width + 1
      if used <= width {
        Some(
          self.theme.f_border_muted("── ") +
          activity +
          " " +
          self.theme.f_border_muted("─".repeat(width - used)),
        )
      } else if activity_width + 2 <= width {
        let left = (width - activity_width) / 2
        Some(
          self.theme.f_border_muted("─".repeat(left)) +
          activity +
          self.theme.f_border_muted("─".repeat(width - left - activity_width)),
        )
      } else {
        Some(self.theme.f_border_muted("─".repeat(width)))
      }
    }
  }
}
