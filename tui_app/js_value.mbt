// JS 值原语(Value / Object)。
//
// 取自 moonbit-community/js-ffi@0.4.2(Apache-2.0,与本仓库同许可)的 Value/Object
// 子集,只保留 tui 包用到的部分(上游的 Optional/Nullable/Union/Symbol/Cast 等未纳入),
// 以便随仓库演进而不受上游版本变动影响。

///|
/// 一个 JS 值(任意 JS 对象/函数/原始值)。
#external
pub type Value

///|
pub fn[T] Value::cast_from(value : T) -> Value = "%identity"

///|
pub fn[T] Value::cast(self : Value) -> T = "%identity"

///|
pub extern "js" fn Value::to_string(self : Value) -> String = "(self) => self.toString()"

///|
pub extern "js" fn Value::is_undefined(self : Value) -> Bool = "(value) => Object.is(value, undefined)"

///|
pub extern "js" fn Value::is_array(self : Value) -> Bool = "(value) => Array.isArray(value)"

///|
extern "js" fn Value::undefined() -> Value = "() => undefined"

///|
pub fn[T] Value::get_with_string(self : Value, key : String) -> T {
  self.get_ffi(Value::cast_from(key)).cast()
}

///|
pub fn[T] Value::set_with_string(self : Value, key : String, value : T) -> Unit {
  self.set_ffi(Value::cast_from(key), Value::cast_from(value))
}

///|
/// `self(...args)`
pub fn[Arg, Result] Value::apply(self : Value, args : Array[Arg]) -> Result {
  self.apply_self_ffi(Value::cast_from(args)).cast()
}

///|
/// `self[key](...args)`
pub fn[Arg, Result] Value::apply_with_string(
  self : Value,
  key : String,
  args : Array[Arg],
) -> Result {
  self.apply_ffi(Value::cast_from(key), Value::cast_from(args)).cast()
}

///|
/// `new self(...args)`
pub fn[Arg, Result] Value::new(self : Value, args : Array[Arg]) -> Result {
  self.new_self_ffi(Value::cast_from(args)).cast()
}

///|
/// `new self[key](...args)`
pub fn[Arg, Result] Value::new_with_string(
  self : Value,
  key : String,
  args : Array[Arg],
) -> Result {
  self.new_ffi(Value::cast_from(key), Value::cast_from(args)).cast()
}

///|
extern "js" fn Value::get_ffi(self : Value, key : Value) -> Value = "(object, key) => object[key]"

///|
extern "js" fn Value::set_ffi(self : Value, key : Value, value : Value) -> Unit = "(object, key, value) => { object[key] = value; }"

///|
extern "js" fn Value::apply_ffi(
  self : Value,
  key : Value,
  args : Value,
) -> Value = "(self, key, args) => self[key](...args)"

///|
extern "js" fn Value::apply_self_ffi(self : Value, args : Value) -> Value = "(self, args) => self(...args)"

///|
extern "js" fn Value::new_ffi(self : Value, key : Value, args : Value) -> Value = "(self, key, args) => new self[key](...args)"

///|
extern "js" fn Value::new_self_ffi(self : Value, args : Value) -> Value = "(self, args) => new self(...args)"

///|
/// 普通 JS 对象(`{}`),用于构造 options/条目。
pub struct Object(Value)

///|
pub extern "js" fn Object::new() -> Object = "() => new Object()"

///|
pub fn Object::to_value(self : Object) -> Value {
  self.0
}

///|
#alias("_[_]")
pub fn[K, V] Object::get(self : Object, key : K) -> V {
  self.0.get_ffi(Value::cast_from(key)).cast()
}

///|
#alias("_[_]=_")
pub fn[K, V] Object::set(self : Object, key : K, value : V) -> Unit {
  self.0.set_ffi(Value::cast_from(key), Value::cast_from(value))
}

///|
/// 空参数表(供泛型调用点消歧义)。
fn no_args() -> Array[Value] {
  []
}

///|
/// `object[key](...args)`,结果类型由调用点标注推断。
fn[T] call(object : Value, key : String, args : Array[Value]) -> T {
  object.apply_with_string(key, args)
}

///|
/// `object[key]`,结果类型由调用点标注推断。
fn[T] get(object : Value, key : String) -> T {
  object.get_with_string(key)
}
