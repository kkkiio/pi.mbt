// pi-tui 的组件/布局薄包装:MoonBit 侧的 `Widget` 协议 + 现成组件构造器。
//
// 设计:只有**内容型**组件写在 MoonBit 侧(transcript/status/footer),
// 布局与交互组件(VStack/ScrollView/Editor)直接复用 pi-tui 的 TS 实现。

///|
fn set(object : Value, key : String, value : Value) -> Unit {
  object.set_with_string(key, value)
}

///|
/// 一个 pi-tui 组件句柄。
pub struct Component {
  handle : Value
}

///|
/// MoonBit 侧组件协议。`render` 每帧按当前宽度产出若干行,必须是同步纯函数
/// (pi-tui 在布局/差分渲染路径上同步调用它,期间不能 await)。
///
/// 行契约:返回数组的**每个元素正好是终端的一行**——不得包含 `\n`/`\r`。
/// pi-tui 按行索引写屏(`\x1b[<row>;1H \x1b[2K <line>`)且只重画「模型串变了的行」;
/// 元素里带换行时,终端会把后半段写到视窗下方的物理行(dock / 输入框),
/// 而那些行的模型串没变 → 差分不会重画 → 内容残留在输入框里。
pub trait Widget {
  fn render(Self, Int) -> Array[String]
  fn invalidate(Self) -> Unit = _
}

///|
/// 默认实现:只有缓存渲染结果的组件才需要覆写。
impl Widget with fn invalidate(self) {
  let _ = self
}

///|
/// 用「按宽度取行」的闭包注册一个 pi-tui `Component`。
/// 闭包直接捕获组件对象即可(MoonBit 的 struct 是引用语义,读到的是当前状态)。
pub fn component_of(render : (Int) -> Array[String]) -> Component {
  Component::{
    handle: js_component(fn(width) { FixedArray::from_array(render(width)) }, fn() {
      ()
    }),
  }
}

///|
/// 把 MoonBit 组件注册成 pi-tui 的 `Component`。
pub fn[W : Widget] mount(widget : W) -> Component {
  Component::{
    handle: js_component(
      fn(width) { FixedArray::from_array(widget.render(width)) },
      fn() { widget.invalidate() },
    ),
  }
}

///|
/// 把 MoonBit 组件(trait object)注册成 pi-tui 的 `Component`。
pub fn mount_ref(widget : &Widget) -> Component {
  Component::{
    handle: js_component(
      fn(width) { FixedArray::from_array(widget.render(width)) },
      fn() { widget.invalidate() },
    ),
  }
}

///|
/// 带内边距的文本块(pi-tui `Text`)。
pub fn text(
  content : String,
  padding_x? : Int = 1,
  padding_y? : Int = 0,
) -> Component {
  let args : Array[Value] = [
    Value::cast_from(content),
    Value::cast_from(padding_x),
    Value::cast_from(padding_y),
  ]
  Component::{ handle: ns_get("Text").new(args), }
}

///|
/// Markdown 块(pi-tui `Markdown`,由 marked 解析)。
pub fn markdown(
  content : String,
  padding_x? : Int = 1,
  padding_y? : Int = 0,
) -> Component {
  let args : Array[Value] = [
    Value::cast_from(content),
    Value::cast_from(padding_x),
    Value::cast_from(padding_y),
  ]
  Component::{ handle: ns_get("Markdown").new(args), }
}

///|
/// 空行。
pub fn spacer(lines? : Int = 1) -> Component {
  Component::{ handle: ns_get("Spacer").new([Value::cast_from(lines)]), }
}

///|
/// 最多显示 `max_lines` 行的文本(pi-tui `TruncatedText`)。
pub fn truncated_text(
  content : String,
  max_lines? : Int = 1,
  padding_x? : Int = 0,
) -> Component {
  let args : Array[Value] = [
    Value::cast_from(content),
    Value::cast_from(padding_x),
    Value::cast_from(max_lines),
  ]
  Component::{ handle: ns_get("TruncatedText").new(args), }
}

///|
/// 纵向堆叠的子项:尺寸语义见 pi-tui `stack.ts`。
/// `basis` 为 `None` 表示按内容测量(`"auto"`),`Some(n)` 表示固定基准高度。
pub struct StackChild {
  component : Component
  basis : Int?
  grow : Int
  shrink : Int
  min_size : Int
}

///|
pub fn stack_child(
  component : Component,
  basis? : Int? = None,
  grow? : Int = 0,
  shrink? : Int = 1,
  min_size? : Int = 0,
) -> StackChild {
  StackChild::{ component, basis, grow, shrink, min_size, }
}

///|
fn StackChild::to_js(self : StackChild) -> Value {
  let entry = Object::new()
  entry["component"] = self.component.handle
  entry["basis"] = match self.basis {
    Some(value) => Value::cast_from(value)
    None => Value::undefined()
  }
  entry["grow"] = self.grow
  entry["shrink"] = self.shrink
  entry["minSize"] = self.min_size
  entry.to_value()
}

///|
/// 纵向堆叠(pi-tui `VStack`)。
pub fn vstack(children : Array[StackChild]) -> Component {
  let entries = js_array(children.map(child => child.to_js()))
  Component::{ handle: ns_get("VStack").new([entries]), }
}

///|
/// 纵向堆叠,子项直接给组件(按内容高度)。
pub fn vstack_auto(children : Array[Component]) -> Component {
  vstack(children.map(component => stack_child(component)))
}

///|
/// 可滚动视窗(pi-tui `ScrollView`)。`primary` 的视窗是滚轮/搜索/选择的靶子。
pub struct ScrollView {
  handle : Value
}

///|
pub fn scroll_view(
  child : Component,
  follow_end? : Bool = true,
  primary? : Bool = true,
  overscroll? : String = "chain",
  scrollbar? : String = "auto",
) -> ScrollView {
  let options = Object::new()
  options["follow"] = if follow_end { "end" } else { "none" }
  options["primary"] = primary
  options["overscroll"] = overscroll
  options["scrollbar"] = scrollbar
  ScrollView::{
    handle: ns_get("ScrollView").new([child.handle, options.to_value()]),
  }
}

///|
pub fn ScrollView::component(self : ScrollView) -> Component {
  Component::{ handle: self.handle, }
}

///|
/// 当前滚动位置(逻辑行)。
pub fn ScrollView::scroll_top(self : ScrollView) -> Int {
  get(self.handle, "scrollTop")
}

///|
/// 是否仍跟随输出尾部(用户往上滚过则为假)。
pub fn ScrollView::is_following_end(self : ScrollView) -> Bool {
  get(self.handle, "isFollowingEnd")
}

///|
pub fn ScrollView::scroll_by(self : ScrollView, lines : Int) -> Unit {
  let _ : Value = call(self.handle, "scrollBy", [Value::cast_from(lines)])
}

///|
pub fn ScrollView::scroll_to_start(self : ScrollView) -> Unit {
  let _ : Value = call(self.handle, "scrollToStart", no_args())
}

///|
pub fn ScrollView::scroll_to_end(self : ScrollView) -> Unit {
  let _ : Value = call(self.handle, "scrollToEnd", no_args())
}

///|
/// 提示符编辑器(pi-tui `Editor`):编辑/历史/补全/多行都在 pi-tui 里,
/// 我们只接提交回调并读写文本。
pub struct Editor {
  handle : Value
}

///|
/// 构造 pi-tui 编辑器(用 JS 子类覆写 `renderTopBorder`,颜色取自注入的主题)。
pub fn editor_new(
  tui : Tui,
  on_submit : (String) -> Unit,
  theme : Theme,
) -> Editor {
  Editor::{
    handle: js_editor_new(
      ns_get("Editor"),
      tui.handle,
      on_submit,
      js_callback_text(fn(text) { theme.f_border_muted(text) }),
      js_callback_text(fn(text) { theme.f_accent(text) }),
      js_callback_text(fn(text) { theme.f_muted(text) }),
    ),
  }
}

///|
/// 设置顶部边框渲染:`render(width)` 返回整行;返回空串则用默认边框。
pub fn Editor::set_border_provider(
  self : Editor,
  render : (Int) -> String,
) -> Unit {
  js_editor_border_provider(self.handle, render)
}

///|
/// 配置 slash 命令补全(`名称 + 描述`)。
pub fn Editor::set_slash_commands(
  self : Editor,
  commands : Array[(String, String)],
  base_path : String,
) -> Unit {
  let items = commands.map(fn(pair) {
    let (name, description) = pair
    let item = Object::new()
    item["name"] = name
    item["description"] = description
    item.to_value()
  })
  let args : Array[Value] = [
    js_array(items),
    Value::cast_from(base_path),
    Value::undefined(),
  ]
  let provider : Value = ns_get("CombinedAutocompleteProvider").new(args)
  let _ : Value = call(self.handle, "setAutocompleteProvider", [provider])
}

///|
/// 把 `(String) -> String` 的 MoonBit 回调变成可存储的 JS 函数值。
extern "js" fn js_callback_text(callback : (String) -> String) -> Value = "(callback) => callback"

///|
/// 绑定顶部边框渲染函数。
extern "js" fn js_editor_border_provider(
  handle : Value,
  render : (Int) -> String,
) -> Unit = "(editor, render) => { editor.borderProvider = render; }"

///|
/// 构造带状态边框的编辑器子类。
extern "js" fn js_editor_new(
  editor_class : Value,
  tui : Value,
  on_submit : (String) -> Unit,
  border_color : Value,
  accent_color : Value,
  muted_color : Value,
) -> Value =
  #| (Editor, tui, on_submit, borderColor, accentColor, mutedColor) => {
  #|   class PimEditor extends Editor {
  #|     constructor(t, th, options) {
  #|       super(t, th, options);
  #|       this.borderProvider = undefined;
  #|     }
  #|     renderTopBorder(width, hiddenLineCount) {
  #|       if (this.borderProvider && width > 0) {
  #|         const line = this.borderProvider(width);
  #|         if (line) return line;
  #|       }
  #|       return super.renderTopBorder(width, hiddenLineCount);
  #|     }
  #|   }
  #|   const editor = new PimEditor(tui, {
  #|     borderColor: borderColor,
  #|     selectList: {
  #|       selectedPrefix: accentColor,
  #|       selectedText: accentColor,
  #|       description: mutedColor,
  #|       scrollInfo: mutedColor,
  #|       noMatch: mutedColor,
  #|     },
  #|   }, {});
  #|   editor.onSubmit = on_submit;
  #|   return editor;
  #| }

///|
pub fn Editor::component(self : Editor) -> Component {
  Component::{ handle: self.handle, }
}

///|
pub fn Editor::get_text(self : Editor) -> String {
  call(self.handle, "getText", no_args())
}

///|
pub fn Editor::set_text(self : Editor, text : String) -> Unit {
  let _ : Value = call(self.handle, "setText", [Value::cast_from(text)])
}

///|
pub fn Editor::add_to_history(self : Editor, text : String) -> Unit {
  let _ : Value = call(self.handle, "addToHistory", [Value::cast_from(text)])
}

///|
/// 编辑器是否正在显示补全菜单(此时全局键位不应抢占)。
pub fn Editor::is_showing_autocomplete(self : Editor) -> Bool {
  call(self.handle, "isShowingAutocomplete", no_args())
}

///|
/// 可见宽度(东亚宽字符按 2 列计),用于对齐与截断。
pub fn visible_width(value : String) -> Int {
  ns_get("visibleWidth").apply([Value::cast_from(value)])
}

///|
/// 按可见宽度截断(超宽加省略号)。
pub fn truncate_to_width(value : String, width : Int) -> String {
  let args : Array[Value] = [Value::cast_from(value), Value::cast_from(width)]
  ns_get("truncateToWidth").apply(args)
}

///|
/// 按可见宽度换行,保留 ANSI 样式。
pub fn wrap_text(value : String, width : Int) -> Array[String] {
  let args : Array[Value] = [Value::cast_from(value), Value::cast_from(width)]
  let lines : FixedArray[String] = ns_get("wrapTextWithAnsi").apply(args)
  Array::makei(lines.length(), index => lines[index])
}

///|
/// 按键匹配:`key` 是**按键名**(`"escape"`、`"ctrl+c"`、`"pageUp"`),对应 pi-tui 的
/// `matchesKey(data, keyId)`(keys.ts)。注意不要用 `KeybindingsManager::matches` ——
/// 那个接口收的是键位 id(`"tui.altScreen.bottom"`),传按键名会静默返回 false。
pub fn matches_key(data : String, key : String) -> Bool {
  let args : Array[Value] = [Value::cast_from(data), Value::cast_from(key)]
  ns_get("matchesKey").apply(args)
}

///|
/// 是否是按键释放事件(Kitty 协议)。
pub fn is_key_release(data : String) -> Bool {
  ns_get("isKeyRelease").apply([Value::cast_from(data)])
}
