///|
/// Processed `@file` arguments containing `<file>` text blocks and inline image attachments.
#derive(Eq, Debug)
pub struct ProcessedFiles {
  text : String
  images : Array[AttachedImage]
}

///|
pub extend ProcessedFiles with Eq::{not_equal, equal}

///|
pub extend ProcessedFiles with @debug.Debug::{to_repr}

///|
/// Base64-encoded inline image attachment.
#derive(Eq, Debug)
pub struct AttachedImage {
  data : String
  mime_type : String
}

///|
pub extend AttachedImage with Eq::{not_equal, equal}

///|
pub extend AttachedImage with @debug.Debug::{to_repr}

///|
/// Resolves `@file` arguments against `cwd` (`~` expanded to home directory) into `<file>` text blocks and base64 `images`.
/// Skips empty files; raises `FsError` if a file does not exist or cannot be read.
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
    let sniff_bytes = if bytes.length() > 4100 {
      bytes[:4100]
    } else {
      bytes[:]
    }
    match detect_supported_image_mime_type(sniff_bytes) {
      Some("image/bmp") =>
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
/// Sniffs a supported image MIME type (`image/jpeg`, `image/png`, `image/gif`, `image/webp`, or `image/bmp`) from magic `bytes`, or returns `None` (excluding JPEG-XL and animated PNG).
pub fn detect_supported_image_mime_type(bytes : BytesView) -> String? {
  if bytes.has_prefix(b"\xff\xd8\xff"[:]) {
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

///|
let png_signature : Bytes = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a"

///|
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
fn read_u16le(bytes : BytesView, offset : Int32) -> Int32 {
  byte_or_zero(bytes, offset) | (byte_or_zero(bytes, offset + 1) << 8)
}

///|
fn read_u32be(bytes : BytesView, offset : Int32) -> Int64 {
  (byte_or_zero(bytes, offset).to_int64() << 24) |
  (byte_or_zero(bytes, offset + 1).to_int64() << 16) |
  (byte_or_zero(bytes, offset + 2).to_int64() << 8) |
  byte_or_zero(bytes, offset + 3).to_int64()
}

///|
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
fn is_png(bytes : BytesView) -> Bool {
  bytes.length() >= 16 &&
  read_u32be(bytes, 8) == 13 &&
  bytes[12:16] == b"IHDR"[:]
}

///|
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
