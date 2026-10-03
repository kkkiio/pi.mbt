// 底部信息栏:两行,对齐 pi `components/footer.ts`。
//
//   行1:`~/cwd (branch) • session`(全 dim)
//   行2:`↑in ↓out Rcache Wcache CH% $cost` + 右对齐 `model • thinking`
//
// 用量累计整个会话,git 分支与会话名由 app/session_host 接线。
// 上下文窗口还没有模型元数据源,未知时不显示。

///|
/// HOME 目录(把 footer 里的绝对路径缩成 `~`)。
extern "js" fn home_dir() -> String = "() => process.env.HOME || process.env.USERPROFILE || ''"

///|
/// 固定格式化为三位小数(与 pi `toFixed(3)` 一致)。
extern "js" fn format_cost(value : Float) -> String = "(value) => value.toFixed(3)"

///|
/// 固定格式化为一位小数。
extern "js" fn format_percent(value : Float) -> String = "(value) => value.toFixed(1)"

///|
/// Footer labels must not be able to inject terminal rows or control sequences.
extern "js" fn sanitize_label(value : String) -> String =
  #|(value) => value.replace(/[\x00-\x1f\x7f]/g, ' ').replace(/ +/g, ' ').trim()

///|
/// Compact count formatting uses pi's rounding (not integer truncation).
extern "js" fn format_footer_count(value : Int) -> String =
  #|(value) => value < 1000 ? String(value) : value < 10000 ? `${(value / 1000).toFixed(1)}k` : value < 1000000 ? `${Math.round(value / 1000)}k` : value < 10000000 ? `${(value / 1000000).toFixed(1)}M` : `${Math.round(value / 1000000)}M`

///|
/// 底部模型、目录与用量信息栏。
pub struct Footer {
  theme : Theme
  model : String
  cwd : String
  thinking : String
  /// git 分支(pi 显示 ` (branch)`);None 时不显示。
  mut branch : String?
  /// 会话名(pi 显示 ` • session`);None 时不显示。
  mut session_name : String?
  mut usage_set : Bool
  mut input_tokens : Int
  mut output_tokens : Int
  mut cache_read : Int
  mut cache_write : Int
  mut total_cost : Float
  /// 最近一次请求的缓存命中率(0–100),未知时为 None。
  mut cache_hit_rate : Float?
  /// 上下文占用比例(0–100)与窗口大小,未知时 None。
  mut context_percent : Float?
  mut context_window : Int?
  mut auto_compact : Bool
}

///|
/// 创建底部信息栏。
pub fn Footer::new(
  theme : Theme,
  model : String,
  cwd : String,
  thinking : String,
) -> Footer {
  Footer::{
    theme,
    model,
    cwd,
    thinking,
    branch: None,
    session_name: None,
    usage_set: false,
    input_tokens: 0,
    output_tokens: 0,
    cache_read: 0,
    cache_write: 0,
    total_cost: 0.0,
    cache_hit_rate: None,
    context_percent: None,
    context_window: None,
    auto_compact: false,
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
/// 累计用量;最近一次模型调用同时更新缓存命中率。
pub fn Footer::set_usage(
  self : Footer,
  usage : @agent_loop.Usage,
  update_cache_hit? : Bool = true,
) -> Unit {
  self.usage_set = true
  self.input_tokens += usage.input
  self.output_tokens += usage.output
  self.cache_read += usage.cache_read
  self.cache_write += usage.cache_write
  self.total_cost += usage.cost.total
  if update_cache_hit {
    let prompt = usage.input + usage.cache_read + usage.cache_write
    self.cache_hit_rate = if prompt > 0 {
      Some(Float::from_int(usage.cache_read) / Float::from_int(prompt) * 100.0)
    } else {
      None
    }
  }
}

///|
/// Clear accumulated usage before replaying a different session.
pub fn Footer::reset_usage(self : Footer) -> Unit {
  self.usage_set = false
  self.input_tokens = 0
  self.output_tokens = 0
  self.cache_read = 0
  self.cache_write = 0
  self.total_cost = 0.0
  self.cache_hit_rate = None
}

///|
pub fn Footer::set_branch(self : Footer, branch : String?) -> Unit {
  self.branch = branch.map(sanitize_label)
}

///|
pub fn Footer::set_session_name(self : Footer, name : String?) -> Unit {
  self.session_name = name.map(sanitize_label)
}

///|
/// 设置上下文占用比例与窗口大小(数据源接线前不会调用)。
pub fn Footer::set_context(
  self : Footer,
  percent : Float,
  window : Int,
) -> Unit {
  self.context_percent = Some(percent)
  self.context_window = Some(window)
}

///|
/// Set a known context window while its current occupancy is unknown.
pub fn Footer::set_context_unknown(self : Footer, window : Int) -> Unit {
  self.context_percent = None
  self.context_window = Some(window)
}

///|
/// 设置是否启用自动压缩(仅影响上下文段的后缀)。
pub fn Footer::set_auto_compact(self : Footer, enabled : Bool) -> Unit {
  self.auto_compact = enabled
}

///|
/// 取得目录在 footer 中的简写(把 HOME 前缀换成 `~`)。
fn display_cwd(path : String) -> String {
  let home = home_dir()
  if home.is_empty() {
    path
  } else if path == home {
    "~"
  } else if path.has_prefix("\{home}/") {
    "~" + path[home.length():].to_owned()
  } else {
    path
  }
}

///|
/// 行1:`cwd (branch) • session`。
fn Footer::path_line(self : Footer) -> String {
  let mut line = display_cwd(self.cwd)
  match self.branch {
    Some(branch) if !branch.is_empty() => line = "\{line} (\{branch})"
    _ => ()
  }
  match self.session_name {
    Some(name) if !name.is_empty() => line = "\{line} • \{name}"
    _ => ()
  }
  line
}

///|
/// 行2 左侧(不含上下文段):`↑in ↓out Rcache Wcache CH% $cost`,单空格分隔。
fn Footer::stats_prefix(self : Footer) -> String {
  let parts : Array[String] = []
  if self.input_tokens > 0 {
    parts.push("↑\{format_footer_count(self.input_tokens)}")
  }
  if self.output_tokens > 0 {
    parts.push("↓\{format_footer_count(self.output_tokens)}")
  }
  if self.cache_read > 0 {
    parts.push("R\{format_footer_count(self.cache_read)}")
  }
  if self.cache_write > 0 {
    parts.push("W\{format_footer_count(self.cache_write)}")
  }
  match self.cache_hit_rate {
    Some(rate) =>
      if self.cache_read > 0 || self.cache_write > 0 {
        parts.push("CH\{format_percent(rate)}%")
      }
    None => ()
  }
  if self.total_cost > 0.0 {
    parts.push("$\{format_cost(self.total_cost)}")
  }
  parts.join(" ")
}

///|
/// 上下文占用文本:`41.7%/200k (auto)`;未知时 `None`。
fn Footer::context_text(self : Footer) -> String? {
  match self.context_percent {
    Some(percent) => {
      let window = match self.context_window {
        Some(value) => format_footer_count(value)
        None => "?"
      }
      let suffix = if self.auto_compact { " (auto)" } else { "" }
      Some("\{format_percent(percent)}%/\{window}\{suffix}")
    }
    None =>
      match self.context_window {
        Some(window) => Some("?/\{format_footer_count(window)}")
        None => None
      }
  }
}

///|
/// 行2 左侧,上下文段按阈值着色(>90 error、>70 warning)。
fn Footer::stats_left(self : Footer) -> String {
  let prefix = self.stats_prefix()
  match self.context_text() {
    Some(context) => {
      let percent = match self.context_percent {
        Some(value) => value
        None => 0.0
      }
      let colored = if percent > 90.0 {
        self.theme.f_error(context)
      } else if percent > 70.0 {
        self.theme.f_warning(context)
      } else {
        self.theme.f_dim(context)
      }
      if prefix.is_empty() {
        colored
      } else {
        self.theme.f_dim(prefix) + " " + colored
      }
    }
    None => self.theme.f_dim(prefix)
  }
}

///|
/// 行2 右侧:`model • thinking`(pi:off 时写 `thinking off`,否则只写档位)。
fn Footer::right_side(self : Footer) -> String {
  if self.model.is_empty() {
    return ""
  }
  if self.thinking.is_empty() {
    self.model
  } else if self.thinking == "off" {
    "\{self.model} • thinking off"
  } else {
    "\{self.model} • \{self.thinking}"
  }
}

///|
/// 把 `left` 与 `right` 排成一行,右侧右对齐(至少留 2 空格);空间不足时截断右侧。
fn align_line(left : String, right : String, width : Int) -> String {
  if right.is_empty() {
    return truncate_to_width(left, width)
  }
  let left_width = visible_width(left)
  let right_width = visible_width(right)
  if left_width + 2 + right_width <= width {
    return left + " ".repeat(width - left_width - right_width) + right
  }
  let available = width - left_width - 2
  if available > 0 {
    let truncated : String = ns_get("truncateToWidth").apply([
      Value::cast_from(right),
      Value::cast_from(available),
      Value::cast_from(""),
    ])
    let pad = width - left_width - visible_width(truncated)
    left + " ".repeat(if pad > 0 { pad } else { 0 }) + truncated
  } else {
    truncate_to_width(left, width)
  }
}

///|
/// 渲染底栏两行(全 dim,上下文段按阈值着色)。
impl Widget for Footer with fn render(self, width) {
  if width <= 0 {
    return [self.theme.f_dim("")]
  }
  let path_line = truncate_to_width(self.theme.f_dim(self.path_line()), width)
  let stats_line = truncate_to_width(
    align_line(self.stats_left(), self.theme.f_dim(self.right_side()), width),
    width,
  )
  [path_line, stats_line]
}
