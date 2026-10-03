// 主题:解析 pi 的 theme JSON(`tui_app/theme/<name>.json`)。
//
// 文件格式与 pi 一致:
//   - `vars`   命名色(name → "#rrggbb")
//   - `colors` 语义角色(role → "#rrggbb" 或某个 var 名)
// 解析后 `ThemeColors` 里全是 `#rrggbb`,渲染只按角色取色(见 `style.mbt`)。
//
// 主题在**构建期**嵌入:`moon tool embed` 把 `theme/<name>.json` 转成
// `theme_builtin_gen.mbt`(见 `moon.pkg` 的 `dev_build`)。运行时零文件查找。
//
// 主题是**值**不是全局:调用方(`TuiApp::start`)载入后按构造器注入各组件,
// 渲染路径上不做任何查找,也没有进程级单例。

///|
/// 解析后的语义色:字段名即角色名,值都是 `#rrggbb`。
///
/// 必需角色用字段表示,构造器逐个校验 JSON;缺字段在载入期报错。
pub struct ThemeColors {
  text : String
  muted : String
  dim : String
  accent : String
  border : String
  border_muted : String
  success : String
  error : String
  warning : String
  thinking_text : String
  custom_message_label : String
  md_link : String
  md_code : String
  md_code_block : String
  md_code_block_border : String
  user_message_bg : String
  tool_pending_bg : String
  tool_success_bg : String
  tool_error_bg : String
  bash_mode : String
  selected_bg : String
  scrollbar_track : String
  scrollbar_thumb : String
  search_match_bg : String
  search_match_text : String
  user_message_text : String
  tool_title : String
  tool_output : String
  md_heading : String
  md_link_url : String
  md_quote : String
  md_quote_border : String
  md_hr : String
  md_list_bullet : String
  thinking_off : String
  thinking_minimal : String
  thinking_low : String
  thinking_medium : String
  thinking_high : String
  thinking_xhigh : String
  thinking_max : String
}

///|
/// 一个已解析的主题:名字 + 语义色。
pub struct Theme {
  name : String
  colors : ThemeColors
}

///|
fn theme_source(name : String) -> String? {
  match name {
    "light" => Some(light_theme)
    _ => None
  }
}

///|
/// 从 `vars` 中取名色,没有就原样返回(可能就是 `#rrggbb`)。
fn resolve_color(vars : Map[String, Json], value : String) -> String {
  if value.has_prefix("#") {
    return value
  }
  match vars.get(value) {
    Some(String(hex)) => hex
    _ => value
  }
}

///|
/// 取一个必需角色;缺键在**载入期**报错,避免渲染时才发现。
fn require_color(
  colors : Map[String, String],
  theme : String,
  role : String,
) -> String raise Failure {
  match colors.get(role) {
    Some(hex) => hex
    None => fail("built-in theme '\{theme}' is missing color role '\{role}'")
  }
}

///|
/// 载入并解析内置主题(源码见 `theme_source`)。
pub fn Theme::load(name : String) -> Theme raise Failure {
  let source = match theme_source(name) {
    Some(source) => source
    None => fail("unknown built-in theme '\{name}' (available: light)")
  }
  let parsed : Json = @json.parse(source) catch {
    _ => fail("built-in theme '\{name}' is not valid JSON")
  }
  guard parsed is Object(root) else {
    fail("built-in theme '\{name}' must be a JSON object")
  }
  let vars : Map[String, Json] = match root {
    { "vars": Object(values), .. } => values
    _ => {}
  }
  guard root is { "colors": Object(raw_colors), .. } else {
    fail("built-in theme '\{name}' has no 'colors' object")
  }
  // JSON 的 role → (hex | var 名) 先解析成 role → `#rrggbb`。
  let resolved : Map[String, String] = Map([])
  for role, json in raw_colors {
    if json is String(text) {
      resolved[role] = resolve_color(vars, text)
    }
  }
  let colors = ThemeColors::{
    text: require_color(resolved, name, "text"),
    muted: require_color(resolved, name, "muted"),
    dim: require_color(resolved, name, "dim"),
    accent: require_color(resolved, name, "accent"),
    border: require_color(resolved, name, "border"),
    border_muted: require_color(resolved, name, "borderMuted"),
    success: require_color(resolved, name, "success"),
    error: require_color(resolved, name, "error"),
    warning: require_color(resolved, name, "warning"),
    thinking_text: require_color(resolved, name, "thinkingText"),
    custom_message_label: require_color(resolved, name, "customMessageLabel"),
    md_link: require_color(resolved, name, "mdLink"),
    md_code: require_color(resolved, name, "mdCode"),
    md_code_block: require_color(resolved, name, "mdCodeBlock"),
    md_code_block_border: require_color(resolved, name, "mdCodeBlockBorder"),
    user_message_bg: require_color(resolved, name, "userMessageBg"),
    tool_pending_bg: require_color(resolved, name, "toolPendingBg"),
    tool_success_bg: require_color(resolved, name, "toolSuccessBg"),
    tool_error_bg: require_color(resolved, name, "toolErrorBg"),
    bash_mode: require_color(resolved, name, "bashMode"),
    selected_bg: require_color(resolved, name, "selectedBg"),
    scrollbar_track: require_color(resolved, name, "scrollbarTrack"),
    scrollbar_thumb: require_color(resolved, name, "scrollbarThumb"),
    search_match_bg: require_color(resolved, name, "searchMatchBg"),
    search_match_text: require_color(resolved, name, "searchMatchText"),
    user_message_text: require_color(resolved, name, "userMessageText"),
    tool_title: require_color(resolved, name, "toolTitle"),
    tool_output: require_color(resolved, name, "toolOutput"),
    md_heading: require_color(resolved, name, "mdHeading"),
    md_link_url: require_color(resolved, name, "mdLinkUrl"),
    md_quote: require_color(resolved, name, "mdQuote"),
    md_quote_border: require_color(resolved, name, "mdQuoteBorder"),
    md_hr: require_color(resolved, name, "mdHr"),
    md_list_bullet: require_color(resolved, name, "mdListBullet"),
    thinking_off: require_color(resolved, name, "thinkingOff"),
    thinking_minimal: require_color(resolved, name, "thinkingMinimal"),
    thinking_low: require_color(resolved, name, "thinkingLow"),
    thinking_medium: require_color(resolved, name, "thinkingMedium"),
    thinking_high: require_color(resolved, name, "thinkingHigh"),
    thinking_xhigh: require_color(resolved, name, "thinkingXhigh"),
    thinking_max: require_color(resolved, name, "thinkingMax"),
  }
  Theme::{ name, colors, }
}

///|
/// Return a resolved semantic color. Unknown roles are programmer errors.
pub fn Theme::color(self : Theme, role : String) -> String {
  match role {
    "text" => self.colors.text
    "muted" => self.colors.muted
    "dim" => self.colors.dim
    "accent" => self.colors.accent
    "border" => self.colors.border
    "borderMuted" => self.colors.border_muted
    "success" => self.colors.success
    "error" => self.colors.error
    "warning" => self.colors.warning
    "thinkingText" => self.colors.thinking_text
    "customMessageLabel" => self.colors.custom_message_label
    "mdLink" => self.colors.md_link
    "mdCode" => self.colors.md_code
    "mdCodeBlock" => self.colors.md_code_block
    "mdCodeBlockBorder" => self.colors.md_code_block_border
    "userMessageBg" => self.colors.user_message_bg
    "toolPendingBg" => self.colors.tool_pending_bg
    "toolSuccessBg" => self.colors.tool_success_bg
    "toolErrorBg" => self.colors.tool_error_bg
    "bashMode" => self.colors.bash_mode
    "selectedBg" => self.colors.selected_bg
    "scrollbarTrack" => self.colors.scrollbar_track
    "scrollbarThumb" => self.colors.scrollbar_thumb
    "searchMatchBg" => self.colors.search_match_bg
    "searchMatchText" => self.colors.search_match_text
    "userMessageText" => self.colors.user_message_text
    "toolTitle" => self.colors.tool_title
    "toolOutput" => self.colors.tool_output
    "mdHeading" => self.colors.md_heading
    "mdLinkUrl" => self.colors.md_link_url
    "mdQuote" => self.colors.md_quote
    "mdQuoteBorder" => self.colors.md_quote_border
    "mdHr" => self.colors.md_hr
    "mdListBullet" => self.colors.md_list_bullet
    "thinkingOff" => self.colors.thinking_off
    "thinkingMinimal" => self.colors.thinking_minimal
    "thinkingLow" => self.colors.thinking_low
    "thinkingMedium" => self.colors.thinking_medium
    "thinkingHigh" => self.colors.thinking_high
    "thinkingXhigh" => self.colors.thinking_xhigh
    "thinkingMax" => self.colors.thinking_max
    _ => abort("unknown theme color role: \{role}")
  }
}

///|
/// 主题名。
pub fn Theme::theme_name(self : Theme) -> String {
  self.name
}
