// 提示符输入:包装 pi-tui 的 `Editor`。
//
// 编辑/历史/补全/多行/粘贴都由 pi-tui 处理,提交时 pi-tui 会清空输入并回调
// `onSubmit`(见 `components/editor.ts` 的 `submitValue`)。

///|
pub struct PromptEditor {
  editor : Editor
}

///|
pub fn prompt_editor_new(
  tui : Tui,
  on_submit : (String) -> Unit,
) -> PromptEditor {
  PromptEditor::{ editor: editor_new(tui, on_submit), }
}

///|
/// 重设提交回调(视图层在装配完成后接线)。
pub fn PromptEditor::set_on_submit(
  self : PromptEditor,
  on_submit : (String) -> Unit,
) -> Unit {
  set(self.editor.handle, "onSubmit", js_callback_string(on_submit))
}

///|
pub fn PromptEditor::component(self : PromptEditor) -> Component {
  self.editor.component()
}

///|
/// 禁用/启用提交(agent 运行中仍可输入,但不提交)。
pub fn PromptEditor::set_submit_enabled(
  self : PromptEditor,
  enabled : Bool,
) -> Unit {
  set(self.editor.handle, "disableSubmit", Value::cast_from(!enabled))
}

///|
pub fn PromptEditor::text(self : PromptEditor) -> String {
  self.editor.get_text()
}

///|
/// 把文本填回输入框(例如把排队消息取回来编辑)。
pub fn PromptEditor::set_text(self : PromptEditor, text : String) -> Unit {
  self.editor.set_text(text)
}

///|
pub fn PromptEditor::add_to_history(self : PromptEditor, text : String) -> Unit {
  self.editor.add_to_history(text)
}

///|
pub fn PromptEditor::is_showing_autocomplete(self : PromptEditor) -> Bool {
  self.editor.is_showing_autocomplete()
}
