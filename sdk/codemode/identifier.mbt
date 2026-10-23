///|
/// 工具名 -> 脚本侧标识符:非标识符字符替换为 `_`
/// (对应 pi toCodemodeIdentifier)。
/// 脚本用 `tools.<id>(args)` 或 `tools["<raw name>"](args)` 两种形式调用。
pub fn to_codemode_identifier(name : String) -> String {
  if name.is_empty() {
    return "_"
  }
  let buffer = StringBuilder()
  for i, char in name {
    let valid = if i == 0 {
      char is ('a'..<='z' | 'A'..<='Z' | '_' | '$')
    } else {
      char is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '_' | '$')
    }
    buffer.write_char(if valid { char } else { '_' })
  }
  buffer.to_string()
}
