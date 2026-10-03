// 聊天记录内容组件:把消息模型同步渲染成终端行。
//
// Markdown、换行与布局复用 pi-tui;消息和工具状态由本包维护。
//
// `render(width)` 是同步纯函数:只读当前状态,不访问外部、不 await。

///|
/// 聊天记录中的一项。
enum TranscriptItem {
  Startup
  /// 用户消息(整块背景,pi `userMessageBg`)。
  User(String)
  /// 系统提示 / 普通信息(dim)。
  Note(String)
  /// 错误信息(error 色)。
  Error(String)
  /// assistant 内容按到达顺序保存;Bool 为 true 时是 thinking。
  Assistant(Array[(String, Bool)], String?, String?)
  /// 工具调用 + 可选结果:name, args, result, is_error;按 call id 配对。
  Tool(String, Json, String?, Bool, Json?, Double?, Double?, id~ : String)
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
  tool_overrides : Map[Int, Bool]
  thinking_overrides : Map[String, Bool]
  /// One latest render per message block; streaming replaces entries instead of growing the cache.
  markdown_cache : Map[String, (String, Int, Bool, String, Array[String])]
  generic_tool_cache : Map[Int, (Int, Bool, Bool, Array[String])]
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
const BASH_PREVIEW_LINES : Int = 5

///|
/// 内容左内边距(pi 的 paddingX=1)。
const PAD : Int = 1

///|
/// 创建空的聊天记录。
///
/// 主题在构造时注入:渲染是同步纯函数,不读取任何全局状态。
pub fn Transcript::new(theme : Theme) -> Transcript {
  {
    theme,
    items: [],
    expanded_tool_output: false,
    expanded_thinking: true,
    tool_overrides: Map([]),
    thinking_overrides: Map([]),
    markdown_cache: Map([]),
    generic_tool_cache: Map([]),
  }
}

///|
/// 向记录追加一条用户消息。
pub fn Transcript::push_user(self : Transcript, text : String) -> Unit {
  self.push_item(TranscriptItem::User(keep_text(text)))
}

///|
pub fn Transcript::push_startup(self : Transcript) -> Unit {
  self.push_item(TranscriptItem::Startup)
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
  self.push_item(TranscriptItem::Assistant([], None, None))
}

///|
/// 把流式 assistant 文本追加到最后一条 assistant 消息。
pub fn Transcript::append_text(self : Transcript, delta : String) -> Unit {
  self.append_content(delta, false)
}

///|
/// 把流式 assistant 思考内容追加到最后一条 assistant 消息。
pub fn Transcript::append_thinking(self : Transcript, delta : String) -> Unit {
  self.append_content(delta, true)
}

///|
fn Transcript::append_content(
  self : Transcript,
  delta : String,
  thinking : Bool,
) -> Unit {
  let index = self.ensure_assistant()
  match self.items[index] {
    TranscriptItem::Assistant(blocks, _, _) => {
      let last = blocks.length() - 1
      if last >= 0 && blocks[last].1 == thinking {
        blocks[last] = (append_text_bounded(blocks[last].0, delta), thinking)
      } else {
        blocks.push((keep_text(delta), thinking))
      }
    }
    _ => ()
  }
}

///|
/// Replace an in-flight snapshot without regrouping text and thinking runs.
pub fn Transcript::set_assistant_content(
  self : Transcript,
  content : Array[(String, Bool)],
) -> Unit {
  let index = self.ensure_assistant()
  let blocks : Array[(String, Bool)] = []
  for (text, thinking) in content {
    let last = blocks.length() - 1
    if thinking && last >= 0 && blocks[last].1 {
      blocks[last] = (keep_text(blocks[last].0 + "\n\n" + text), true)
    } else {
      blocks.push((keep_text(text), thinking))
    }
  }
  match self.items[index] {
    TranscriptItem::Assistant(_, reason, error) =>
      self.items[index] = TranscriptItem::Assistant(blocks, reason, error)
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
    TranscriptItem::Assistant(blocks, _, _) =>
      self.items[index] = TranscriptItem::Assistant(
        blocks,
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
  timed? : Bool = false,
) -> Unit {
  self.push_item(
    TranscriptItem::Tool(
      keep_text(name),
      arguments,
      None,
      false,
      None,
      if timed {
        Some(now_ms())
      } else {
        None
      },
      None,
      id~,
    ),
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
  details? : Json? = None,
) -> Unit {
  let mut index = self.items.length()
  while index > 0 {
    index -= 1
    match self.items[index] {
      TranscriptItem::Tool(
        tool_name,
        arguments,
        None,
        _,
        _,
        started,
        _,
        id=call_id
      ) if call_id == id => {
        self.items[index] = TranscriptItem::Tool(
          tool_name,
          arguments,
          Some(keep_text(text)),
          is_error,
          details,
          started,
          started.map(_ => now_ms()),
          id~,
        )
        self.generic_tool_cache.remove(index) |> ignore
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
      details,
      None,
      None,
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
  self.tool_overrides.clear()
}

///|
/// 设置是否展开思考内容(`Ctrl+T`)。
pub fn Transcript::set_expanded_thinking(
  self : Transcript,
  expanded : Bool,
) -> Unit {
  self.expanded_thinking = expanded
  self.thinking_overrides.clear()
}

///|
/// 切换思考内容的展开状态(`Ctrl+T`)。
pub fn Transcript::toggle_expanded_thinking(self : Transcript) -> Unit {
  self.set_expanded_thinking(!self.expanded_thinking)
}

///|
/// 切换工具输出的展开状态(`Ctrl+O`)。
pub fn Transcript::toggle_expanded_tool_output(self : Transcript) -> Unit {
  self.set_expanded_tool_output(!self.expanded_tool_output)
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
    let rendered = render_item(self, item, safe_width, index)
    if rendered.is_empty() {
      continue
    }
    if !lines.is_empty() {
      lines.push("")
    }
    for line in rendered {
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
/// Left-click coordinates are logical document rows, retargeted by ScrollView.
/// Recompute spans at the current width so resizing cannot leave stale hit areas.
pub fn Transcript::click(self : Transcript, row : Int, width : Int) -> Bool {
  let mut top = 0
  for index, item in self.items {
    let rendered = render_item(self, item, width, index)
    if rendered.is_empty() {
      continue
    }
    if top > 0 {
      top += 1
    }
    if row >= top && row < top + rendered.length() {
      match item {
        TranscriptItem::Tool(name, args, Some(_), error, _, _, _, ..) => {
          let expanded = self.tool_overrides
            .get(index)
            .unwrap_or(self.expanded_tool_output)
          let header = render_tool(
            self,
            name,
            args,
            None,
            error,
            None,
            None,
            None,
            width,
            expanded~,
          )
          if row - top >= header.length() - 1 {
            self.tool_overrides[index] = !expanded
            return true
          }
        }
        TranscriptItem::Assistant(blocks, _, _) => {
          let mut block_top = top
          let mut has_content = false
          for block_index, (text, thinking) in blocks {
            if text.trim().is_empty() {
              continue
            }
            if has_content {
              block_top += 1
            }
            let key = "\{index}:\{block_index}"
            let expanded = self.thinking_overrides
              .get(key)
              .unwrap_or(self.expanded_thinking)
            let rows = render_assistant_block(
              self, text, thinking, expanded, width, key,
            )
            if thinking && row >= block_top && row < block_top + rows.length() {
              self.thinking_overrides[key] = !expanded
              return true
            }
            has_content = true
            block_top += rows.length()
          }
        }
        _ => ()
      }
      return false
    }
    top += rendered.length()
  }
  false
}

///|
/// 追加项并限制模型大小;保留一条省略提示作为历史边界。
fn Transcript::push_item(self : Transcript, item : TranscriptItem) -> Unit {
  if self.items.length() >= MAX_ITEMS {
    self.items = self.items[2:].to_owned()
    self.tool_overrides.clear()
    self.thinking_overrides.clear()
    self.markdown_cache.clear()
    self.generic_tool_cache.clear()
    self.items.push(TranscriptItem::Note("… earlier messages omitted"))
  }
  self.items.push(item)
}

///|
/// 找到最后一条 assistant,没有时就创建一条。
fn Transcript::ensure_assistant(self : Transcript) -> Int {
  if self.items.is_empty() {
    self.start_assistant()
  } else {
    let last = self.items.length() - 1
    match self.items[last] {
      TranscriptItem::Assistant(_, _, _) => ()
      _ => self.start_assistant()
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
  index : Int,
) -> Array[String] {
  let theme = transcript.theme
  match item {
    TranscriptItem::Startup => {
      let hints = [
        ("Esc", "interrupt"),
        ("Ctrl+C/Ctrl+D", "clear/exit"),
        ("/", "commands"),
        ("Ctrl+O", "more"),
      ]
      let compact = hints
        .map(fn(pair) { theme.f_dim(pair.0) + " " + theme.f_muted(pair.1) })
        .join(theme.f_muted(" · "))
      let content = if transcript.expanded_tool_output {
        [
          ("Esc", "to interrupt"),
          ("Ctrl+C", "to clear"),
          ("Ctrl+C twice", "to exit"),
          ("Ctrl+D", "to exit (empty)"),
          ("Ctrl+O", "to expand tools"),
          ("Ctrl+T", "to expand thinking"),
          ("/", "for commands"),
        ]
        .map(fn(pair) { theme.f_dim(pair.0) + " " + theme.f_muted(pair.1) })
        .join("\n")
      } else {
        compact + "\n" + theme.f_dim("Press Ctrl+O to show full startup help.")
      }
      let rows : Array[String] = []
      for row in physical_lines(bold(theme.f_accent("pim")) + "\n" + content) {
        for line in wrap_text(row, available_width(width, PAD * 2)) {
          rows.push(pad_left(line, PAD))
        }
      }
      rows
    }
    TranscriptItem::User(text) =>
      render_user(transcript, text, width, "user:\{index}")
    TranscriptItem::Note(text) =>
      render_plain(text, fn(text) { theme.f_dim(text) }, width)
    TranscriptItem::Error(text) =>
      render_plain(text, fn(text) { theme.f_error(text) }, width)
    TranscriptItem::Assistant(blocks, stop_reason, error_message) =>
      render_assistant(
        transcript, blocks, stop_reason, error_message, width, index,
      )
    TranscriptItem::Tool(
      name,
      arguments,
      result,
      is_error,
      details,
      started,
      ended,
      ..
    ) => {
      let expanded = transcript.tool_overrides
        .get(index)
        .unwrap_or(transcript.expanded_tool_output)
      let true_color = terminal_true_color()
      if name != "bash" &&
        transcript.generic_tool_cache.get(index)
        is Some((cached_width, cached_expanded, cached_color, rows)) &&
        cached_width == width &&
        cached_expanded == expanded &&
        cached_color == true_color {
        return rows
      }
      let rows = render_tool(
        transcript,
        name,
        arguments,
        result,
        is_error,
        details,
        started,
        ended,
        width,
        expanded~,
      )
      if name != "bash" {
        transcript.generic_tool_cache[index] = (
          width, expanded, true_color, rows,
        )
      }
      rows
    }
  }
}

///|
/// 用户消息:整块 `userMessageBg` 背景,上下各留一行 padding(pi `Box(padX=1,padY=1)`)。
fn render_user(
  transcript : Transcript,
  text : String,
  width : Int,
  key : String,
) -> Array[String] {
  let theme = transcript.theme
  let bg = fn(text : String) { theme.bg_user(text) }
  let lines : Array[String] = []
  lines.push(bg_blank(bg, width))
  let content_width = available_width(width, PAD * 2)
  for
    wrapped in transcript.cached_markdown(
      key,
      physical_lines(text).join("\n"),
      content_width,
      body_role="userMessageText",
      user=true,
    ) {
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
  let content_width = available_width(width, PAD * 2)
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
  blocks : Array[(String, Bool)],
  stop_reason : String?,
  error_message : String?,
  width : Int,
  item_index : Int,
) -> Array[String] {
  let theme = transcript.theme
  let lines : Array[String] = []
  for block_index, (text, thinking) in blocks {
    if text.trim().is_empty() {
      continue
    }
    if !lines.is_empty() {
      lines.push("")
    }
    let expanded = transcript.thinking_overrides
      .get("\{item_index}:\{block_index}")
      .unwrap_or(transcript.expanded_thinking)
    for
      line in render_assistant_block(
        transcript,
        text,
        thinking,
        expanded,
        width,
        "\{item_index}:\{block_index}",
      ) {
      lines.push(line)
    }
  }
  let notice = match stop_reason {
    Some("length") => Some("Response was truncated before completion.")
    Some("aborted") =>
      Some(
        match error_message {
          Some(message) if message != "Request was aborted" &&
            !message.is_empty() => message
          _ => "Operation aborted"
        },
      )
    Some("error") => Some("Error: " + error_message.unwrap_or("Unknown error"))
    _ => None
  }
  if notice is Some(message) {
    if !lines.is_empty() {
      lines.push("")
    }
    for line in render_plain(message, fn(text) { theme.f_error(text) }, width) {
      lines.push(line)
    }
  }
  lines
}

///|
fn render_assistant_block(
  transcript : Transcript,
  text : String,
  thinking : Bool,
  expanded : Bool,
  width : Int,
  key : String,
) -> Array[String] {
  if thinking && !expanded {
    [pad_left(italic(transcript.theme.f_thinking("Thinking...")), PAD)]
  } else {
    transcript.cached_markdown(
      key,
      text,
      width,
      body_role=if thinking { "thinkingText" } else { "text" },
      body_italic=thinking,
    )
  }
}

///|
fn Transcript::cached_markdown(
  self : Transcript,
  key : String,
  text : String,
  width : Int,
  body_role~ : String,
  body_italic? : Bool = false,
  user? : Bool = false,
) -> Array[String] {
  let true_color = terminal_true_color()
  if self.markdown_cache.get(key)
    is Some((cached_text, cached_width, cached_color, cached_role, lines)) &&
    cached_text == text &&
    cached_width == width &&
    cached_color == true_color &&
    cached_role == body_role {
    return lines
  }
  let lines = render_markdown_themed(
    self.theme,
    text,
    width,
    padding_x=if user { 0 } else { 1 },
    body_role~,
    body_italic~,
    preserve_ordered_markers=user,
    preserve_backslash_escapes=user,
  )
  self.markdown_cache[key] = (text, width, true_color, body_role, lines)
  lines
}

///|
/// Agent tool calls use the status-colored shell; `!` shell mode is separate in pi.
fn render_tool(
  transcript : Transcript,
  name : String,
  arguments : Json,
  result : String?,
  is_error : Bool,
  details : Json?,
  started : Double?,
  ended : Double?,
  width : Int,
  expanded~ : Bool,
) -> Array[String] {
  if name == "bash" {
    render_bash(
      transcript,
      arguments,
      result,
      is_error,
      details,
      started,
      ended,
      width,
      expanded~,
    )
  } else {
    render_tool_generic(
      transcript,
      name,
      arguments,
      result,
      is_error,
      width,
      expanded~,
    )
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
/// 通用工具块与 read 回放使用状态背景。
///
/// pi 的 read 渲染是 `read <path>:<range>`,且折叠时不显示结果;这里同样处理。
fn render_tool_generic(
  transcript : Transcript,
  name : String,
  arguments : Json,
  result : String?,
  is_error : Bool,
  width : Int,
  expanded~ : Bool,
) -> Array[String] {
  let theme = transcript.theme
  let bg = theme.tool_bg(result, is_error)
  let lines : Array[String] = []
  lines.push(bg_blank(bg, width))
  let is_read = name == "read" || name == "read_file"
  let header = if is_read {
    match arg_string(arguments, ["path", "file_path"]) {
      Some(path) =>
        theme.fg("toolTitle", bold("read")) +
        " " +
        theme.f_accent(path) +
        read_range(theme, arguments)
      None => bold(theme.f_text(name))
    }
  } else {
    theme.fg("toolTitle", bold(name))
  }
  let content_width = available_width(width, PAD * 2)
  for row in wrap_text(header, content_width) {
    lines.push(bg_line(bg, " " + row, width))
  }
  if !is_read {
    lines.push(bg_blank(bg, width))
    let limit = if expanded { 50 } else { 10 }
    let mut shown = 0
    let mut omitted = false
    for row in physical_lines(pretty_arguments(arguments)) {
      for wrapped in wrap_text(row, content_width) {
        if shown >= limit {
          omitted = true
          break
        }
        lines.push(bg_line(bg, " " + wrapped, width))
        shown += 1
      }
      if omitted {
        break
      }
    }
    if omitted {
      lines.push(
        bg_line(
          bg,
          " " +
          truncate_to_width(
            theme.f_muted("... (arguments truncated)"),
            content_width,
          ),
          width,
        ),
      )
    }
  }
  let show_result = !is_read || expanded || is_error
  match result {
    Some(text) if show_result && !text.is_empty() => {
      lines.push(bg_blank(bg, width))
      // TODO: read 的代码输出语法高亮随 Markdown 代码块一起对齐 pi。
      let rendered = text.replace_all(old="\t", new="   ")
      for
        line in result_preview(
          theme,
          rendered,
          TOOL_PREVIEW_LINES,
          expanded,
          content_width,
          tail=false,
        ) {
        lines.push(bg_line(bg, " " + line, width))
      }
    }
    _ => ()
  }
  lines.push(bg_blank(bg, width))
  lines
}

///|
/// Agent bash uses a status background and a five-visual-line tail preview.
fn render_bash(
  transcript : Transcript,
  arguments : Json,
  result : String?,
  is_error : Bool,
  details : Json?,
  started : Double?,
  ended : Double?,
  width : Int,
  expanded~ : Bool,
) -> Array[String] {
  let theme = transcript.theme
  let bg = theme.tool_bg(result, is_error)
  let lines : Array[String] = []
  let content_width = available_width(width, PAD * 2)
  lines.push(bg_blank(bg, width))
  let command = match arg_string(arguments, ["command"]) {
    Some(value) => value
    None => ""
  }
  for index, command_line in physical_lines(command) {
    let prefix = if index == 0 { "$ " } else { "" }
    let timeout = if index == 0 {
      match arguments {
        Object(fields) =>
          match fields.get("timeout") {
            Some(Number(seconds, ..)) => theme.f_muted(" (timeout \{seconds}s)")
            _ => ""
          }
        _ => ""
      }
    } else {
      ""
    }
    for
      wrapped in wrap_text(
        theme.fg("toolTitle", bold(prefix + command_line)) + timeout,
        content_width,
      ) {
      lines.push(bg_line(bg, " " + wrapped, width))
    }
  }
  let output = result.map(fn(text) { bash_output(text, details) })
  match output {
    Some(text) if !text.is_empty() => {
      lines.push(bg_blank(bg, width))
      for
        line in result_preview(
          theme,
          text,
          BASH_PREVIEW_LINES,
          expanded,
          content_width,
          tail=true,
        ) {
        lines.push(bg_line(bg, " " + line, width))
      }
    }
    _ => ()
  }
  if details is Some(Object(fields)) {
    let warnings : Array[String] = []
    if fields.get("fullOutputPath") is Some(String(path)) {
      warnings.push("Full output: " + path)
    }
    if fields.get("truncation") is Some(Object(truncation)) &&
      truncation.get("truncated") is Some(True) {
      if truncation.get("outputLines") is Some(Number(shown, ..)) &&
        truncation.get("totalLines") is Some(Number(total, ..)) {
        if truncation.get("truncatedBy") is Some(String("lines")) {
          warnings.push("Truncated: showing \{shown} of \{total} lines")
        } else {
          let max_bytes = match truncation.get("maxBytes") {
            Some(Number(bytes, ..)) => bytes
            _ => 51200.0
          }
          warnings.push(
            "Truncated: \{shown} lines shown (" +
            format_output_size(max_bytes) +
            " limit)",
          )
        }
      }
    }
    if !warnings.is_empty() {
      lines.push(bg_blank(bg, width))
      for
        row in wrap_text(
          theme.f_warning("[" + warnings.join(". ") + "]"),
          content_width,
        ) {
        lines.push(bg_line(bg, " " + row, width))
      }
    }
  }
  if started is Some(started) {
    let label = if ended is Some(_) { "Took" } else { "Elapsed" }
    let duration = format_tool_duration(ended.unwrap_or(now_ms()) - started)
    lines.push(bg_blank(bg, width))
    lines.push(bg_line(bg, " " + theme.f_muted("\{label} \{duration}"), width))
  }
  lines.push(bg_blank(bg, width))
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
    for wrapped in wrap_text(theme.fg("toolOutput", row), width) {
      all.push(wrapped)
    }
  }
  let total = all.length()
  let shown = if expanded || total <= max_lines { total } else { max_lines }
  let start = if tail { total - shown } else { 0 }
  let lines : Array[String] = []
  if shown < total {
    let remaining = total - shown
    let hint = theme.f_muted(
        "... (\{remaining} " +
        (if tail { "earlier" } else { "more" }) +
        " lines, ",
      ) +
      key_hint(theme, "ctrl+o") +
      theme.f_muted(" to expand)")
    if tail {
      lines.push(truncate_to_width(hint, width))
    }
    for row in all[start:start + shown] {
      lines.push(row)
    }
    if !tail {
      lines.push(truncate_to_width(hint, width))
    }
  } else {
    for row in all {
      lines.push(row)
    }
  }
  lines
}

///|
/// 键盘提示的小片段(pi keyHint:暗色按键 + muted 描述,这里按键用 dim 反显)。
fn key_hint(theme : Theme, key : String) -> String {
  theme.f_dim(key)
}

///|
fn pretty_arguments(arguments : Json) -> String {
  js_pretty_arguments(arguments.stringify())
}

///|
extern "js" fn js_pretty_arguments(arguments : String) -> String =
  #| (value) => { const formatted = JSON.stringify(JSON.parse(value), null, 2); return formatted.length > 65536 ? formatted.slice(0,65536) + '\n... (arguments truncated)' : formatted; }

///|
fn read_range(theme : Theme, arguments : Json) -> String {
  guard arguments is Object(fields) else { return "" }
  let offset = fields.get("offset")
  let limit = fields.get("limit")
  if offset is None && limit is None {
    return ""
  }
  let start = match offset {
    Some(Number(n, ..)) => n
    _ => 1.0
  }
  let end = match limit {
    Some(Number(n, ..)) => "-\{start + n - 1.0}"
    _ => ""
  }
  theme.f_warning(":\{start}\{end}")
}

///|
fn bash_output(text : String, details : Json?) -> String {
  let path = match details {
    Some(Object(fields)) if fields.get("truncation") is Some(Object(truncation)) &&
      truncation.get("truncated") is Some(True) =>
      match fields.get("fullOutputPath") {
        Some(String(path)) => path
        _ => ""
      }
    _ => ""
  }
  strip_bash_footer(text, path)
}

///|
extern "js" fn strip_bash_footer(text : String, path : String) -> String =
  #| (text, path) => { const index = text.lastIndexOf('\n\n['); return path && text.endsWith(']') && index >= 0 && text.slice(index).includes(path) ? text.slice(0,index) : text; }

///|
extern "js" fn format_output_size(bytes : Double) -> String =
  #| bytes => bytes < 1024 ? `${bytes}B` : bytes < 1048576 ? `${(bytes/1024).toFixed(1)}KB` : `${(bytes/1048576).toFixed(1)}MB`

///|
extern "js" fn format_tool_duration(ms : Double) -> String =
  #| ms => { const seconds = ms/1000; if (seconds < 60) return `${seconds.toFixed(1)}s`; const s = Math.floor(seconds), m = Math.floor(s/60); return m < 60 ? `${m}m ${s%60}s` : `${Math.floor(m/60)}h ${m%60}m ${s%60}s`; }

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
