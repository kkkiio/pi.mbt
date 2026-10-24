///|
/// prelude_source 由 `moon tool embed` 从 prelude.js 生成到
/// prelude_gen.mbt;prelude.js 与 @earendil-works/pi-codemode 的
/// PRELUDE_SOURCE 同源(dist/runtime/prelude-source.js)。
/// js 与 native 两个 VM 喂同一份(js worker 自带 prelude,此常量
/// 主要供 native 内嵌 VM 与测试断言用)。
pub fn codemode_prelude_source() -> String {
  prelude_source
}
