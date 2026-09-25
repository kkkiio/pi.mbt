// 全屏聊天布局的组装(对应 pi 的 `chat-viewport.ts`)。
//
// 结构(详见 README/设计笔记):
//   VStack[ ScrollView(transcript, primary/follow end) grow=1, VStack(dock) basis=auto ]
// transcript 是唯一被滚轮/搜索/选择作用的视窗;dock 固定在底部。

///|
pub struct ChatViewport {
  root : Component
  transcript : ScrollView
}

///|
/// 组装布局。各槽位的职责:
/// - `document`:聊天记录(消息流)
/// - `pending`:排队中的用户消息
/// - `status`:运行状态(idle/working)
/// - `editor`:提示符输入
/// - `footer`:模型/cwd/用量底栏
pub fn chat_viewport_new(
  document~ : Component,
  pending~ : Component,
  status~ : Component,
  editor~ : Component,
  footer~ : Component,
  scrollbar? : String = "auto",
) -> ChatViewport {
  let transcript = scroll_view(document, scrollbar~)
  let dock = vstack([
    stack_child(pending, min_size=0),
    stack_child(status, min_size=0),
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
