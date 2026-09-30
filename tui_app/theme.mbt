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
/// 字段齐全由构造处的 struct literal 在**编译期**保证(等价于 TS 的
/// `Record<ThemeColor, string>`),所以取色是 total 的,没有 `Option`/`abort`。
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
  // 这个 literal 就是「必需角色齐全」的编译期检查:漏一个字段编译不过。
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
  }
  Theme::{ name, colors, }
}

///|
/// 主题名。
pub fn Theme::theme_name(self : Theme) -> String {
  self.name
}
