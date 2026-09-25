///|
/// 底部模型、目录与用量信息栏。
pub struct Footer {
  model : String
  cwd : String
  thinking : String
  mut hint : String
  mut usage_set : Bool
  mut input_tokens : Int
  mut output_tokens : Int
  mut total_cost : Float
}

///|
/// 创建底部信息栏。
pub fn Footer::new(model : String, cwd : String, thinking : String) -> Footer {
  Footer::{
    model,
    cwd,
    thinking,
    hint: "",
    usage_set: false,
    input_tokens: 0,
    output_tokens: 0,
    total_cost: 0.0,
  }
}

///|
/// 当前模型 id。
pub fn Footer::model(self : Footer) -> String {
  self.model
}

///|
/// 当前工作目录。
pub fn Footer::cwd(self : Footer) -> String {
  self.cwd
}

///|
/// 当前思考档位。
pub fn Footer::thinking(self : Footer) -> String {
  self.thinking
}

///|
/// 更新最近一次模型调用的用量。
pub fn Footer::set_usage(self : Footer, usage : @agent_loop.Usage) -> Unit {
  self.usage_set = true
  self.input_tokens = usage.input
  self.output_tokens = usage.output
  self.total_cost = usage.cost.total
}

///|
/// 设置右侧的临时提示。
pub fn Footer::set_hint(self : Footer, hint : String) -> Unit {
  self.hint = hint
}

///|
/// 将金额固定格式化为四位小数。
extern "js" fn format_cost(value : Float) -> String = "(value) => value.toFixed(4)"

///|
/// 取得目录在狭窄栏位中的简写。
fn abbreviated_cwd(path : String) -> String {
  match path.rev_split_once("/") {
    Some((_, last)) if !last.is_empty() => "…/\{last}"
    Some((_, _)) => "…/"
    None => "…/\{path}"
  }
}

///|
/// 将一组完整片段拼成一行,提示始终放在最右边。
fn join_footer_segments(
  segments : Array[String],
  count : Int,
  hint : String,
) -> String {
  let selected : Array[String] = []
  for index in 0..<count {
    selected.push(segments[index])
  }
  if !hint.is_empty() {
    selected.push(hint)
  }
  selected.join(" · ")
}

///|
/// 生成不截断片段的最长候选行。
fn choose_footer_line(
  segments : Array[String],
  hint : String,
  width : Int,
) -> String {
  let mut count = segments.length()
  while count >= 0 {
    let candidate = join_footer_segments(segments, count, hint)
    if visible_width(candidate) <= width {
      return candidate
    }
    count -= 1
  }
  if !hint.is_empty() {
    truncate_to_width(hint, width)
  } else if !segments.is_empty() {
    truncate_to_width(segments[0], width)
  } else {
    ""
  }
}

///|
/// 构造底栏的有序片段。
fn Footer::segments(self : Footer, cwd : String) -> Array[String] {
  let segments : Array[String] = []
  if !self.model.is_empty() {
    segments.push(cyan(self.model))
  }
  if !self.thinking.is_empty() {
    segments.push(self.thinking)
  }
  if !cwd.is_empty() {
    segments.push(cwd)
  }
  if self.usage_set {
    let counts = "↑\{format_count(self.input_tokens)} ↓\{format_count(self.output_tokens)}"
    let usage = if self.total_cost > 0.0 {
      "\{counts} $\{format_cost(self.total_cost)}"
    } else {
      counts
    }
    segments.push(usage)
  }
  segments
}

///|
/// 渲染底栏。除必要的最后保险外,候选只会删除完整片段。
impl Widget for Footer with fn render(self, width : Int) -> Array[String] {
  if width <= 0 {
    [dim("")]
  } else {
    let full_segments = self.segments(self.cwd)
    let full_line = join_footer_segments(
      full_segments,
      full_segments.length(),
      self.hint,
    )
    let segments = if visible_width(full_line) <= width {
      full_segments
    } else {
      let short_cwd = abbreviated_cwd(self.cwd)
      self.segments(short_cwd)
    }
    let styled_hint = if self.hint.is_empty() { "" } else { yellow(self.hint) }
    let line = choose_footer_line(segments, styled_hint, width)
    [truncate_to_width(dim(line), width)]
  }
}
