///|
/// 当前运行阶段。
pub enum Phase {
  Idle
  /// 工作态:标签 + 起始时间(epoch 毫秒,Double —— epoch 毫秒放不进 Int)。
  Working(String, Double)
}

///|
/// 输入框上方的运行状态行。
pub struct StatusLine {
  mut current : Phase
  mut spinner_index : Int
  mut elapsed_ms : Int
}

///|
/// 创建一个空闲的状态行。
pub fn StatusLine::new() -> StatusLine {
  StatusLine::{ current: Idle, spinner_index: 0, elapsed_ms: 0, }
}

///|
/// 将状态切换为空闲。
pub fn StatusLine::set_idle(self : StatusLine) -> Unit {
  self.current = Idle
  self.elapsed_ms = 0
}

///|
/// 开始显示工作状态,并记录工作的起始时间。
pub fn StatusLine::set_working(
  self : StatusLine,
  label : String,
  started_ms : Double,
) -> Unit {
  self.current = Working(label, started_ms)
  self.elapsed_ms = 0
}

///|
/// 设置从工作开始算起的已用时间(毫秒)。
///
/// TUI 包未直接导入时钟包时,由外层定时器更新这个值。
pub fn StatusLine::set_elapsed(self : StatusLine, milliseconds : Int) -> Unit {
  self.elapsed_ms = milliseconds
}

///|
/// 前进到下一个 braille 旋转帧。
pub fn StatusLine::tick(self : StatusLine) -> Unit {
  self.spinner_index = (self.spinner_index + 1) % 10
}

///|
/// 返回当前运行阶段。
pub fn StatusLine::phase(self : StatusLine) -> Phase {
  self.current
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
/// 渲染状态行。空闲时返回零行,工作时返回一行有界文本。
impl Widget for StatusLine with fn render(self, width : Int) -> Array[String] {
  match self.current {
    Idle => []
    Working(label, _) => {
      let elapsed = if self.elapsed_ms < 0 { 0 } else { self.elapsed_ms }
      let activity = bold(cyan("\{spinner_frame(self.spinner_index)} \{label}"))
      let timing = dim(" · \{format_elapsed(elapsed)}")
      let line = activity + timing
      if width <= 0 {
        [""]
      } else {
        [truncate_to_width(line, width)]
      }
    }
  }
}
