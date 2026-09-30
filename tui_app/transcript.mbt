// 聊天记录内容组件:把消息模型同步渲染成终端行。
//
// 渲染对齐 pi(见各 render_* 的注释),但**本期不做** diff / 压缩摘要 /
// 分支摘要 / 自定义消息 / mermaid / OSC 8 链接。布局、滚动、增量绘制由 pi-tui 负责。
//
// `render(width)` 是同步纯函数:只读当前状态,不访问外部、不 await。

///|
/// 聊天记录中的一项。
enum TranscriptItem {
  /// 用户消息(整块背景,pi `userMessageBg`)。
  User(String)
  /// 系统提示 / 普通信息(dim)。
  Note(String)
  /// 错误信息(error 色)。
  Error(String)
  /// assistant 消息:text, thinking, stop_reason, error_message。
  Assistant(String, String, String?, String?)
  /// 工具调用 + 可选结果:name, args, result, is_error;按 call id 配对。
  Tool(String, Json, String?, Bool, id~ : String)
}

///|
/// 聊天记录组件,保存用户、assistant 和工具消息的显示模型。
pub struct Transcript {
  theme : Theme
  mut items : Array[TranscriptItem]
  /// 工具输出是否展开(默认折叠,`Ctrl+O` 切换)。
  mut expanded_tool_output : Bool
  /// 思考内容是否展开(默认展开,`Ctrl+T` 折叠)。
  mut expanded_thinking : Bool
}

///|
const MAX_ITEMS : Int = 400

///|
const MAX_RETAINED_TEXT_WIDTH : Int = 65_536

///|
/// 折叠(未展开)时工具结果预览的行数。
const TOOL_PREVIEW_LINES : Int = 10

///|
/// 折叠(未展开)时 bash 输出预览的行数。
const BASH_PREVIEW_LINES : Int = 20

///|
/// 内容左内边距(pi 的 paddingX=1)。
const PAD : Int = 1

///|
/// 创建空的聊天记录。
///
/// 主题在构造时注入:渲染是同步纯函数,不读取任何全局状态。
pub fn Transcript::new(theme : Theme) -> Transcript {
  { theme, items: [], expanded_tool_output: false, expanded_thinking: true, }
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
/// 追加一条工具调用记录(结果随后由 `push_tool_result` 回填)。
pub fn Transcript::push_tool_call(
  self : Transcript,
  name : String,
  arguments : Json,
  id~ : String,
) -> Unit {
  self.push_item(
    TranscriptItem::Tool(keep_text(name), arguments, None, false, id~),
  )
}

///|
/// 按 call id 回填工具结果;调用已被裁掉时补一条只有结果的记录。
pub fn Transcript::push_tool_result(
  self : Transcript,
  name : String,
  text : String,
  is_error : Bool,
  id~ : String,
) -> Unit {
  let mut index = self.items.length()
  while index > 0 {
    index -= 1
    match self.items[index] {
      TranscriptItem::Tool(tool_name, arguments, None, _, id=call_id) if call_id ==
        id => {
        self.items[index] = TranscriptItem::Tool(
          tool_name,
          arguments,
          Some(keep_text(text)),
          is_error,
          id~,
        )
        return
      }
      _ => ()
    }
  }
  self.push_item(
    TranscriptItem::Tool(
      keep_text(name),
      Json::empty_object(),
      Some(keep_text(text)),
      is_error,
      id~,
    ),
  )
}

///|
/// 设置是否展开工具输出(`Ctrl+O`)。
pub fn Transcript::set_expanded_tool_output(
  self : Transcript,
  expanded : Bool,
) -> Unit {
  self.expanded_tool_output = expanded
}

///|
/// 设置是否展开思考内容(`Ctrl+T`)。
pub fn Transcript::set_expanded_thinking(
  self : Transcript,
  expanded : Bool,
) -> Unit {
  self.expanded_thinking = expanded
}

///|
/// 切换思考内容的展开状态(`Ctrl+T`)。
pub fn Transcript::toggle_expanded_thinking(self : Transcript) -> Unit {
  self.expanded_thinking = !self.expanded_thinking
}

///|
/// 切换工具输出的展开状态(`Ctrl+O`)。
pub fn Transcript::toggle_expanded_tool_output(self : Transcript) -> Unit {
  self.expanded_tool_output = !self.expanded_tool_output
}

///|
/// 返回当前保留的顶层消息项数量。
pub fn Transcript::item_count(self : Transcript) -> Int {
  self.items.length()
}

///|
/// 实现 pi-tui 的同步内容组件协议。
///
/// 返回的**每个元素必须正好是一行**:pi-tui 的差分渲染按行索引写
/// (`\x1b[<row>;1H \x1b[2K <line>`)并只重画「模型串变了」的行,所以元素里带
/// `\n`/`\r` 时终端会把后半段写到视窗下方(dock,也就是输入框那几行)的物理行上,
/// 而那些行的模型串没变 → 永远不会被重画 → transcript 内容残留在输入框里。
/// 最终统一拆物理行并截到视口宽度,保护边框、标题和提示等不换行的内容。
pub impl Widget for Transcript with fn render(self : Transcript, width : Int) -> Array[
  String,
] {
  let safe_width = if width < 0 { 0 } else { width }
  let lines : Array[String] = []
  for index, item in self.items {
    if index > 0 {
      lines.push("")
    }
    for line in render_item(self, item, safe_width) {
      for row in physical_lines(line) {
        lines.push(truncate_to_width(row, safe_width))
      }
    }
  }
  lines
}

///|
/// 把一个「行」按物理换行拆开:`\r\n` / `\r` / `\n` 都算换行,与 pi-tui
/// `wrapTextWithAnsi` 的分行语义一致。
///
/// 用于两类地方:一是本身就要按行渲染的文本(工具结果、简单消息、Markdown、bash
/// 命令),二是 `Transcript::render` 的兜底拆分 —— 模型/用户/工具输出都不保证只用
/// `\n`,而终端只看字符,不看我们的「一行」概念。
fn physical_lines(text : String) -> Array[String] {
  let normalized = text
    .replace_all(old="\r\n", new="\n")
    .replace_all(old="\r", new="\n")
  let lines : Array[String] = []
  for line in normalized.split("\n") {
    lines.push(line.to_owned())
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

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

///|
fn render_item(
  transcript : Transcript,
  item : TranscriptItem,
  width : Int,
) -> Array[String] {
  let theme = transcript.theme
  match item {
    TranscriptItem::User(text) => render_user(theme, text, width)
    TranscriptItem::Note(text) =>
      render_plain(text, fn(text) { theme.f_dim(text) }, width)
    TranscriptItem::Error(text) =>
      render_plain(text, fn(text) { theme.f_error(text) }, width)
    TranscriptItem::Assistant(text, thinking, stop_reason, error_message) =>
      render_assistant(
        transcript, text, thinking, stop_reason, error_message, width,
      )
    TranscriptItem::Tool(name, arguments, result, is_error, ..) =>
      render_tool(transcript, name, arguments, result, is_error, width)
  }
}

///|
/// 用户消息:整块 `userMessageBg` 背景,上下各留一行 padding(pi `Box(padX=1,padY=1)`)。
fn render_user(theme : Theme, text : String, width : Int) -> Array[String] {
  let bg = fn(text : String) { theme.bg_user(text) }
  let lines : Array[String] = []
  lines.push(bg_blank(bg, width))
  let content_width = available_width(width, PAD * 2)
  for wrapped in wrap_text(text, content_width) {
    lines.push(bg_line(bg, " ".repeat(PAD) + wrapped, width))
  }
  lines.push(bg_blank(bg, width))
  lines
}

///|
/// 按行换行并统一着色的简单消息(dim / error)。
fn render_plain(
  text : String,
  color : (String) -> String,
  width : Int,
) -> Array[String] {
  let lines : Array[String] = []
  let content_width = available_width(width, PAD)
  for line in physical_lines(text) {
    let rendered = color(line)
    if visible_width(rendered) == 0 {
      lines.push("")
    } else {
      for wrapped in wrap_text(rendered, content_width) {
        lines.push(pad_left(wrapped, PAD))
      }
    }
  }
  if lines.is_empty() {
    lines.push("")
  }
  lines
}

///|
/// assistant 消息:思考段 + 正文(Markdown)+ 停止原因 / 错误。
fn render_assistant(
  transcript : Transcript,
  text : String,
  thinking : String,
  stop_reason : String?,
  error_message : String?,
  width : Int,
) -> Array[String] {
  let theme = transcript.theme
  let lines : Array[String] = []
  if !thinking.is_empty() {
    if transcript.expanded_thinking {
      for
        line in render_markdown(
          theme,
          thinking,
          width,
          PAD,
          fn(text) { theme.f_thinking(text) },
          true,
        ) {
        lines.push(line)
      }
    } else {
      lines.push(pad_left(italic(theme.f_thinking("Thinking...")), PAD))
    }
    lines.push("")
  }
  if !text.is_empty() {
    for
      line in render_markdown(
        theme,
        text,
        width,
        PAD,
        fn(text) { theme.f_text(text) },
        false,
      ) {
      lines.push(line)
    }
  }
  match stop_reason {
    Some(reason) if is_abnormal_stop(reason) =>
      lines.push(pad_left(theme.f_dim("(stopped: \{reason})"), PAD))
    _ => ()
  }
  match error_message {
    Some(message) if !message.is_empty() =>
      for line in render_plain(message, fn(text) { theme.f_error(text) }, width) {
        lines.push(line)
      }
    _ => ()
  }
  lines
}

///|
/// 工具调用 + 结果。bash 走 pi `bash-execution.ts` 的绿框;其余走通用块。
fn render_tool(
  transcript : Transcript,
  name : String,
  arguments : Json,
  result : String?,
  is_error : Bool,
  width : Int,
) -> Array[String] {
  if name == "bash" {
    render_bash(transcript, arguments, result, is_error, width)
  } else {
    render_tool_generic(transcript, name, arguments, result, is_error, width)
  }
}

///|
/// 从参数 JSON 里取一个字符串字段。
fn arg_string(arguments : Json, keys : Array[String]) -> String? {
  guard arguments is Object(fields) else { return None }
  for key in keys {
    match fields.get(key) {
      Some(String(value)) => return Some(value)
      _ => ()
    }
  }
  None
}

///|
/// 通用工具块:粗体工具名 + 参数摘要,结果按预览/展开显示。
///
/// pi 的 read 渲染是 `read <path>:<range>`,且折叠时不显示结果;这里同样处理。
fn render_tool_generic(
  transcript : Transcript,
  name : String,
  arguments : Json,
  result : String?,
  is_error : Bool,
  width : Int,
) -> Array[String] {
  let theme = transcript.theme
  let bg = theme.tool_bg(result, is_error)
  let lines : Array[String] = []
  lines.push(bg_blank(bg, width))
  let is_read = name == "read" || name == "read_file"
  let header = if is_read {
    match arg_string(arguments, ["path", "file_path"]) {
      Some(path) => bold(theme.f_text("read")) + " " + theme.f_accent(path)
      None => bold(theme.f_text(name))
    }
  } else {
    let summary = match
      arg_string(arguments, ["command", "path", "file_path", "pattern", "query"]) {
      Some(value) => value
      None => arguments.stringify()
    }
    // 摘要按设计只占一行(下面会按可用宽度截断):多行参数只取首行并标注省略,
    // 不能把带换行的整串塞进一个元素(会被终端写到视窗下方的物理行)。
    let summary_rows = physical_lines(summary)
    let summary_text = if summary_rows.length() > 1 {
      summary_rows[0] + "..."
    } else {
      summary
    }
    bold(theme.f_text(name)) +
    (if summary_text.is_empty() {
      ""
    } else {
      " " +
      theme.f_dim(
        truncate_to_width(
          summary_text,
          available_width(width, PAD + visible_width(name) + 1),
        ),
      )
    })
  }
  lines.push(bg_line(bg, " ".repeat(PAD) + header, width))
  let show_result = match (is_read, transcript.expanded_tool_output) {
    (true, false) => false
    _ => true
  }
  match result {
    Some(text) if show_result && !text.is_empty() =>
      for
        line in result_preview(
          theme,
          text,
          TOOL_PREVIEW_LINES,
          transcript.expanded_tool_output,
          available_width(width, PAD),
          tail=false,
        ) {
        lines.push(bg_line(bg, " ".repeat(PAD) + theme.f_muted(line), width))
      }
    _ => ()
  }
  lines.push(bg_blank(bg, width))
  lines
}

///|
/// bash 执行块:绿框 + `$ command` + 折叠预览(pi `bash-execution.ts`)。
fn render_bash(
  transcript : Transcript,
  arguments : Json,
  result : String?,
  is_error : Bool,
  width : Int,
) -> Array[String] {
  let theme = transcript.theme
  let lines : Array[String] = []
  let rule = theme.f_bash("─".repeat(if width > 0 { width } else { 0 }))
  lines.push(rule)
  let command = match arg_string(arguments, ["command"]) {
    Some(value) => value
    None => ""
  }
  // 与 pi 一致(pi 用 `Text(theme.fg("bashMode", theme.bold("$ " + command)), 1, 0)`):
  // 命令按物理行展开,`$ ` 只加在第一行,超宽按内容宽度换行。
  // 整串命令塞进一个元素会让 `\n` 后面的行落到视窗下方的物理行(输入框)。
  for index, command_line in physical_lines(command) {
    let prefix = if index == 0 { "$ " } else { "" }
    for
      wrapped in wrap_text(
        theme.f_bash(bold(prefix + command_line)),
        available_width(width, PAD),
      ) {
      lines.push(" ".repeat(PAD) + wrapped)
    }
  }
  match result {
    Some(text) if !text.is_empty() =>
      for
        line in result_preview(
          theme,
          text,
          BASH_PREVIEW_LINES,
          transcript.expanded_tool_output,
          available_width(width, PAD),
          tail=true,
        ) {
        lines.push(" ".repeat(PAD) + theme.f_muted(line))
      }
    _ => ()
  }
  if is_error {
    lines.push(" ".repeat(PAD) + theme.f_error("(exit 1)"))
  }
  lines.push(rule)
  lines
}

///|
/// 先按可用列宽换行,再按可见行数截预览。bash 保留尾部诊断,其余工具保留开头。
fn result_preview(
  theme : Theme,
  text : String,
  max_lines : Int,
  expanded : Bool,
  width : Int,
  tail~ : Bool,
) -> Array[String] {
  let all : Array[String] = []
  for row in physical_lines(text) {
    for wrapped in wrap_text(row, width) {
      all.push(wrapped)
    }
  }
  let total = all.length()
  let shown = if expanded || total <= max_lines { total } else { max_lines }
  let start = if tail { total - shown } else { 0 }
  let lines = all[start:start + shown].to_owned()
  if shown < total {
    let remaining = total - shown
    lines.push(
      theme.f_dim("... (\{remaining} more lines, ") +
      key_hint(theme, "ctrl+o") +
      theme.f_dim(" to expand)"),
    )
  }
  lines
}

///|
/// 键盘提示的小片段(pi keyHint:暗色按键 + muted 描述,这里按键用 dim 反显)。
fn key_hint(theme : Theme, key : String) -> String {
  theme.f_dim(key)
}

// ---------------------------------------------------------------------------
// Markdown(简化版:围栏代码块 + 行内 code/bold)
// ---------------------------------------------------------------------------

///|
/// 渲染 Markdown 文本:围栏代码块按语言高亮,其余行做行内变换后按宽度换行。
fn render_markdown(
  theme : Theme,
  text : String,
  width : Int,
  indent : Int,
  body_color : (String) -> String,
  italic_body : Bool,
) -> Array[String] {
  let lines : Array[String] = []
  let content_width = available_width(width, indent)
  let mut in_fence = false
  let mut lang = ""
  for line in physical_lines(text) {
    let trimmed = line.trim().to_owned()
    if !in_fence && trimmed.has_prefix("```") {
      in_fence = true
      lang = trimmed[3:].to_owned()
      lines.push(pad_left(theme.f_md_border("```" + lang), indent))
    } else if in_fence && trimmed.has_prefix("```") {
      in_fence = false
      lang = ""
      lines.push(pad_left(theme.f_md_border("```"), indent))
    } else if in_fence {
      for wrapped in wrap_text(theme.f_md_code_block(line), content_width) {
        lines.push(pad_left(wrapped, indent))
      }
    } else if trimmed.is_empty() {
      lines.push("")
    } else {
      let rendered = if italic_body {
        italic(body_color(render_inline(theme, line)))
      } else {
        body_color(render_inline(theme, line))
      }
      for wrapped in wrap_text(rendered, content_width) {
        lines.push(pad_left(wrapped, indent))
      }
    }
  }
  lines
}

///|
/// 行内 Markdown:`` `code` `` → mdCode,`**bold**` → 粗体。
fn render_inline(theme : Theme, text : String) -> String {
  let chars = text.to_array()
  let out = StringBuilder()
  let mut buffer = ""
  let mut in_code = false
  let mut in_bold = false
  let mut index = 0
  let length = chars.length()
  while index < length {
    let char = chars[index]
    if char == '`' {
      out.write_string(styled_run(theme, buffer, in_code, in_bold))
      buffer = ""
      in_code = !in_code
      index += 1
    } else if char == '*' && index + 1 < length && chars[index + 1] == '*' {
      out.write_string(styled_run(theme, buffer, in_code, in_bold))
      buffer = ""
      in_bold = !in_bold
      index += 2
    } else {
      buffer = buffer + char.to_string()
      index += 1
    }
  }
  out.write_string(styled_run(theme, buffer, in_code, in_bold))
  out.to_string()
}

///|
/// 渲染一段行内文本(按当前行内状态着色)。
fn styled_run(
  theme : Theme,
  text : String,
  in_code : Bool,
  in_bold : Bool,
) -> String {
  if text.is_empty() {
    ""
  } else if in_code {
    theme.f_md_code(text)
  } else if in_bold {
    bold(text)
  } else {
    text
  }
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

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
/// 判断停止原因是否代表错误或中止。
fn is_abnormal_stop(reason : String) -> Bool {
  reason == "error" ||
  reason == "failed" ||
  reason == "abort" ||
  reason == "aborted" ||
  reason == "cancelled" ||
  reason == "canceled"
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
