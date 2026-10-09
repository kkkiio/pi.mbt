// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "KKKIIO/pi"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/kkkiio/pi.mbt"

license = "Apache-2.0"

keywords = [ ]

preferred_target = "js"

description = "MoonBit agent SDK and pim coding agent CLI"

import {
  "moonbitlang/async@0.22.2",
  "moonbitlang/x@0.5.5",
  "moonbitlang/jsonl@0.2.1",
}
