// 全屏聊天布局的组装(对应 pi 的 `chat-viewport.ts`)。
//
//   VStack[ ScrollView(transcript, primary/follow end) grow=1, VStack(dock) basis=auto ]
//
// transcript 是唯一被滚轮/搜索/选择作用的视窗;dock 固定在底部。
// 运行状态不占 dock 行,而是由 editor 的上边框渲染(见 `StatusLine::render_border`)。

///|
pub struct ChatViewport {
  root : Component
  transcript : ScrollView
}

///|
/// 组装布局。各槽位的职责:
/// - `document`:聊天记录(消息流)
/// - `pending`:排队中的用户消息
/// - `editor`:提示符输入(可就地渲染运行状态)
/// - `footer`:`cwd` / 用量 / 模型信息栏
pub fn chat_viewport_new(
  document~ : Component,
  pending~ : Component,
  editor~ : Component,
  footer~ : Component,
  scrollbar? : String = "auto",
  theme? : Theme? = None,
) -> ChatViewport {
  let transcript = match theme {
    Some(theme) =>
      scroll_view(
        document,
        scrollbar~,
        scrollbar_track_style=Some(fn(text) { theme.fg("scrollbarTrack", text) }),
        scrollbar_thumb_style=Some(fn(text) { theme.fg("scrollbarThumb", text) }),
      )
    None => scroll_view(document, scrollbar~)
  }
  let dock = vstack([
    stack_child(pending, min_size=0),
    stack_child(editor, min_size=3),
    stack_child(footer, min_size=0),
  ])
  let root = vstack([
    stack_child(
      transcript.component(),
      basis=Some(0),
      grow=1,
      shrink=1,
      min_size=1,
    ),
    stack_child(dock, grow=0, shrink=1, min_size=1),
  ])
  ChatViewport::{ root, transcript, }
}

///|
/// 布局根,喂给 `Tui::set_layout_root`。
pub fn ChatViewport::root(self : ChatViewport) -> Component {
  self.root
}

///|
/// 主滚动视窗(需要主动滚动/判断跟随时用)。
pub fn ChatViewport::transcript(self : ChatViewport) -> ScrollView {
  self.transcript
}
