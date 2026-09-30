// 提示符输入:包装 pi-tui 的 `Editor`。
//
// 编辑/历史/补全/多行/粘贴都由 pi-tui 处理,提交时 pi-tui 会清空输入并回调
// `onSubmit`(见 `components/editor.ts` 的 `submitValue`)。

///|
pub struct PromptEditor {
  editor : Editor
  /// 迟到绑定:JS 桥在构造时一次性挂上(转发到这个格子),真正的 handler
  /// 之后由 `set_on_submit` 纯 MoonBit 赋值换入,不再碰 JS handle。
  handler : Ref[(String) -> Unit]
}

///|
pub fn prompt_editor_new(tui : Tui, theme : Theme) -> PromptEditor {
  let handler : Ref[(String) -> Unit] = Ref(fn(_text) { () })
  let editor = editor_new(tui, fn(text) { (handler.val)(text) }, theme)
  PromptEditor::{ editor, handler }
}

///|
/// 接线提交回调(构造后可随时换入,不碰 JS handle)。
pub fn PromptEditor::set_on_submit(
  self : PromptEditor,
  on_submit : (String) -> Unit,
) -> Unit {
  self.handler.val = on_submit
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
/// 设置输入框上边框渲染(用于嵌入运行状态)。
pub fn PromptEditor::set_border_provider(
  self : PromptEditor,
  render : (Int) -> String,
) -> Unit {
  self.editor.set_border_provider(render)
}

///|
/// 配置 slash 命令补全(`名称 + 描述`)。
pub fn PromptEditor::set_slash_commands(
  self : PromptEditor,
  commands : Array[(String, String)],
  base_path : String,
) -> Unit {
  self.editor.set_slash_commands(commands, base_path)
}

///|
pub fn PromptEditor::add_to_history(self : PromptEditor, text : String) -> Unit {
  self.editor.add_to_history(text)
}

///|
pub fn PromptEditor::is_showing_autocomplete(self : PromptEditor) -> Bool {
  self.editor.is_showing_autocomplete()
}
