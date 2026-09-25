// pi-tui 绑定:命名空间载入 + 两处 JS 值原语覆盖不到的桥。
//
//   - `load()`:一次**字面量动态 import**(node 从 node_modules 解析,bun 打包进单文件);
//   - `js_component`/`js_input_listener`:把 MoonBit 闭包以**带类型的参数**交给 JS
//     (Value 原语没有"MoonBit 闭包 → JS 函数"这条桥)。

///|
extern "js" fn import_pi_tui() -> @js_async.Promise[Value] = "() => import('@earendil-works/pi-tui')"

///|
let pi_tui_ns : Ref[Value?] = Ref(None)

///|
/// 载入 pi-tui(幂等)。使用 `tui` 包任何功能前先 await 一次。
pub async fn load() -> Unit {
  match pi_tui_ns.val {
    Some(_) => ()
    None => pi_tui_ns.val = Some(@js_async.Promise::wait(import_pi_tui()))
  }
}

///|
/// 取 pi-tui 的导出(类/函数/常量)。
fn ns_get(key : String) -> Value {
  match pi_tui_ns.val {
    Some(exports) => {
      let exported : Value = exports.get_with_string(key)
      guard !exported.is_undefined() else {
        abort("pi-tui has no export named \{key}")
      }
      exported
    }
    None => abort("pi-tui is not loaded: await tui::load() first")
  }
}

///|
/// 把值数组打包成**单个** JS 数组值(用于"一个数组参数",例如 VStack 的 children)。
fn js_array(values : Array[Value]) -> Value {
  Value::cast_from(FixedArray::from_array(values))
}

///|
/// pi-tui 的 `Component` 协议:每帧按宽度重渲染。
extern "js" fn js_component(
  render : (Int) -> FixedArray[String],
  invalidate : () -> Unit,
) -> Value = "(render, invalidate) => ({ render: (width) => render(width), invalidate: () => invalidate() })"

///|
/// pi-tui 的输入监听器:返回 `{consume: true}` 表示吞掉该输入。
extern "js" fn js_input_listener(handle : (String) -> Bool) -> Value = "(handle) => (data) => (handle(data) ? { consume: true } : undefined)"
