///|
/// pi's `toCodemodeIdentifier`: characters that are not valid in a JavaScript
/// identifier become `_`; an empty name becomes `_`.
pub fn to_codemode_identifier(name : String) -> String {
  let builder = StringBuilder()
  for c in name.iter() {
    let valid = if builder.is_empty() {
      c is ('a'..<='z' | 'A'..<='Z' | '_' | '$')
    } else {
      c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '_' | '$')
    }
    builder.write_char(if valid { c } else { '_' })
  }
  if builder.is_empty() {
    "_"
  } else {
    builder.to_string()
  }
}
