// @file 附件处理:把 CLI 的 `@path` 参数变成首条用户消息里的 `<file>` 文本块
// 和 base64 内联图片附件。
//
// 行为对齐 pi 的 `processFileArguments`(packages/coding-agent/src/cli/
// file-processor.ts):逐 arg 解析路径(`~` 展开、相对 cwd)、跳过空文件、
// 按魔数嗅探图片类型;支持内联的图片走 base64,不支持(如 BMP)降级为占位
// 文案,其余一律当 utf-8 文本注入。
//
// 图片嗅探逻辑复刻 pi 的 `detectSupportedImageMimeType`(utils/mime.ts),
// 包括 JPEG-XL / APNG 的排除规则和 BMP 的 DIB 头校验。

///|
/// 已处理的 `@file` 参数:拼接进首条用户消息的文本与图片附件。
pub struct ProcessedFiles {
  text : String
  images : Array[AttachedImage]
} derive(Eq, Debug)

///|
pub extend ProcessedFiles with Eq::{not_equal, equal}

///|
pub extend ProcessedFiles with @debug.Debug::{to_repr}

///|
/// base64 内联的图片附件(mirrors pi's ImageContent)。
pub struct AttachedImage {
  data : String
  mime_type : String
} derive(Eq, Debug)

///|
pub extend AttachedImage with Eq::{not_equal, equal}

///|
pub extend AttachedImage with @debug.Debug::{to_repr}

///|
/// 把 `@file` 参数处理成文本引用 + 图片附件(pi `processFileArguments`)。
///
/// `file_args` 里的每个参数先按 `cwd` 解析成绝对路径(`~`/`~/` 展开为
/// home 目录),不存在的路径抛 `FsError("File not found: <abs>")`;空文件
/// 直接跳过。之后按前 4100 字节的魔数分流:
///
/// - jpeg/png/gif/webp → base64 进 `images`,text 记 `<file name="abs"></file>`;
/// - bmp → 不做格式转换,text 记 pi 转换失败的降级文案;
/// - 其余 → 当 utf-8 文本(lossy 解码、去 BOM),text 记
///   `<file name="abs">\n<content>\n</file>`。
pub fn process_file_arguments(
  cwd~ : String,
  file_args : ArrayView[String],
) -> ProcessedFiles raise FsError {
  let text = StringBuilder()
  let images : Array[AttachedImage] = []
  for arg in file_args {
    let abs = resolve_attachment_path(cwd, arg)
    if !path_exists(abs) {
      raise FsError("File not found: \{abs}")
    }
    let bytes = read_bytes_file(abs) catch {
      err => raise FsError("Could not read file \{abs}: \{err}")
    }
    if bytes.length() == 0 {
      continue
    }
    // 嗅探只需要文件头,与 pi 的 IMAGE_TYPE_SNIFF_BYTES 一致。
    let sniff_bytes = if bytes.length() > 4100 {
      bytes[:4100]
    } else {
      bytes[:]
    }
    match detect_supported_image_mime_type(sniff_bytes) {
      Some("image/bmp") =>
        // pi 会把 bmp 转成 png 再内联;这里没有格式转换,直接用它
        // processImage 失败时的降级文案。
        text.write_string(
          "<file name=\"\{abs}\">[Image omitted: could not be converted to a supported inline image format.]</file>\n",
        )
      Some(mime_type) => {
        images.push({ data: @base64.encode(bytes[:]), mime_type, })
        text.write_string("<file name=\"\{abs}\"></file>\n")
      }
      None => {
        let decoded = @utf8.decode_lossy(bytes[:])
        let content = match decoded.strip_prefix("\u{feff}") {
          Some(rest) => rest.to_owned()
          None => decoded
        }
        text.write_string("<file name=\"\{abs}\">\n\{content}\n</file>\n")
      }
    }
  }
  { text: text.to_string(), images, }
}

///|
/// 魔数嗅探图片类型;不支持/非图片返回 `None`。
///
/// 识别 jpeg/png/gif/webp/bmp 五种;JPEG-XL(`FF D8 FF F7`)和动画 PNG
/// (IDAT 前出现 acTL chunk)被明确排除,bmp 还要过 DIB 头校验才算数。
pub fn detect_supported_image_mime_type(bytes : BytesView) -> String? {
  if bytes.has_prefix(b"\xff\xd8\xff"[:]) {
    // 第四字节 F7 是 JPEG-XL 的容器签名,不是 jpeg。
    return if bytes.get(3) is Some(0xf7) { None } else { Some("image/jpeg") }
  }
  if bytes.has_prefix(png_signature[:]) {
    return if is_png(bytes) && !is_animated_png(bytes) {
      Some("image/png")
    } else {
      None
    }
  }
  if bytes.has_prefix(b"GIF87a"[:]) || bytes.has_prefix(b"GIF89a"[:]) {
    return Some("image/gif")
  }
  if bytes.length() >= 12 &&
    bytes[:4] == b"RIFF"[:] &&
    bytes[8:12] == b"WEBP"[:] {
    return Some("image/webp")
  }
  if bytes.has_prefix(b"BM"[:]) && is_bmp(bytes) {
    return Some("image/bmp")
  }
  None
}

// ---------------------------------------------------------------------------
// 内部:路径解析与二进制嗅探
// ---------------------------------------------------------------------------

///|
let png_signature : Bytes = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a"

///|
/// 展开 `~`、相对路径拼到 `cwd` 后,再做 POSIX 段规范化(`.`、`..`、
/// 重复斜杠),得到展示用的绝对路径。
fn resolve_attachment_path(cwd : String, arg : String) -> String {
  let joined = if arg == "~" || arg.has_prefix("~/") {
    home_dir() + arg[1:].to_owned()
  } else if arg.has_prefix("/") {
    arg
  } else {
    "\{cwd}/\{arg}"
  }
  let segments : Array[String] = []
  for segment in joined.split("/") {
    match segment {
      "" | "." => ()
      ".." => if segments.length() > 0 { ignore(segments.pop()) }
      _ => segments.push(segment.to_owned())
    }
  }
  "/\{segments.join("/")}"
}

///|
/// 读小端 u16;越界位置按 0 处理(对齐上游 `buffer[i] ?? 0`)。
fn read_u16le(bytes : BytesView, offset : Int32) -> Int32 {
  byte_or_zero(bytes, offset) | (byte_or_zero(bytes, offset + 1) << 8)
}

///|
/// 读大端 u32;用 Int64 承载避免 >0x7fffffff 时回绕成负数。
fn read_u32be(bytes : BytesView, offset : Int32) -> Int64 {
  (byte_or_zero(bytes, offset).to_int64() << 24) |
  (byte_or_zero(bytes, offset + 1).to_int64() << 16) |
  (byte_or_zero(bytes, offset + 2).to_int64() << 8) |
  byte_or_zero(bytes, offset + 3).to_int64()
}

///|
/// 读小端 u32;同 `read_u32be` 用 Int64 防回绕。
fn read_u32le(bytes : BytesView, offset : Int32) -> Int64 {
  byte_or_zero(bytes, offset).to_int64() |
  (byte_or_zero(bytes, offset + 1).to_int64() << 8) |
  (byte_or_zero(bytes, offset + 2).to_int64() << 16) |
  (byte_or_zero(bytes, offset + 3).to_int64() << 24)
}

///|
fn byte_or_zero(bytes : BytesView, offset : Int32) -> Int32 {
  match bytes.get(offset) {
    Some(byte) => byte.to_int()
    None => 0
  }
}

///|
/// PNG 结构校验:签名后是 length=13 的 IHDR chunk。
fn is_png(bytes : BytesView) -> Bool {
  bytes.length() >= 16 &&
  read_u32be(bytes, 8) == 13 &&
  bytes[12:16] == b"IHDR"[:]
}

///|
/// 动画 PNG 判定:扫 chunk 序列,在 IDAT 之前出现 acTL 即动画。
fn is_animated_png(bytes : BytesView) -> Bool {
  let mut offset = 8
  while offset + 8 <= bytes.length() {
    let chunk_length = read_u32be(bytes, offset)
    let type_offset = offset + 4
    if bytes[type_offset:type_offset + 4] == b"acTL"[:] {
      return true
    }
    if bytes[type_offset:type_offset + 4] == b"IDAT"[:] {
      return false
    }
    let next = offset.to_int64() + 8 + chunk_length + 4
    if next <= offset.to_int64() || next > bytes.length().to_int64() {
      return false
    }
    offset = next.to_int()
  }
  false
}

///|
/// BMP 校验:文件头声明的尺寸自洽,且 DIB 头里的 planes/bpp 合法。
fn is_bmp(bytes : BytesView) -> Bool {
  if bytes.length() < 26 {
    return false
  }
  let declared_file_size = read_u32le(bytes, 2)
  let pixel_data_offset = read_u32le(bytes, 10)
  let dib_header_size = read_u32le(bytes, 14)
  if declared_file_size != 0 && declared_file_size < 26 {
    return false
  }
  if pixel_data_offset < 14 + dib_header_size {
    return false
  }
  if declared_file_size != 0 && pixel_data_offset >= declared_file_size {
    return false
  }
  let (planes, bits_per_pixel) = if dib_header_size == 12 {
    (read_u16le(bytes, 22), read_u16le(bytes, 24))
  } else if dib_header_size >= 40 && dib_header_size <= 124 {
    if bytes.length() < 30 {
      return false
    }
    (read_u16le(bytes, 26), read_u16le(bytes, 28))
  } else {
    return false
  }
  planes == 1 && bits_per_pixel is (1 | 4 | 8 | 16 | 24 | 32)
}
