///|
/// 一个最小的静态 PNG:签名 + IHDR chunk + IDAT chunk。
let test_png_bytes : Bytes = [
  // 8 字节签名
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  // IHDR:length=13,type "IHDR",13 字节数据 + 4 字节 CRC
   0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00,
  0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
  // IDAT:length=1,type "IDAT",1 字节数据 + 4 字节 CRC
   0x00, 0x00, 0x00, 0x01, 0x49, 0x44, 0x41, 0x54, 0x00, 0x78, 0x9c, 0x62, 0x62,
]

///|
/// 同样的 PNG,在 IDAT 之前插一个 acTL chunk → 动画 PNG,不支持内联。
let test_apng_bytes : Bytes = [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48,
  0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
  0x00, 0x1f, 0x15, 0xc4, 0x89,
  // acTL:length=8,type "acTL"
   0x00, 0x00, 0x00, 0x08, 0x61, 0x63, 0x54, 0x4c, 0x00, 0x00, 0x00, 0x01, 0x00,
  0x00, 0x00, 0x01, 0x12, 0x34, 0x56, 0x78,
  // IDAT
   0x00, 0x00, 0x00, 0x01, 0x49, 0x44, 0x41, 0x54, 0x00, 0x78, 0x9c, 0x62, 0x62,
]

///|
/// 30 字节的最小 BMP 头:DIB 40 字节头、planes=1、bpp=24。
let test_bmp_bytes : Bytes = [
  // "BM" + declared file size 58(pixel offset 54 < 58,自洽)
  0x42, 0x4d, 0x3a, 0x00, 0x00, 0x00,
  // reserved
   0x00, 0x00, 0x00, 0x00,
  // pixel data offset = 54
   0x36, 0x00, 0x00, 0x00,
  // DIB header size = 40
   0x28, 0x00, 0x00, 0x00,
  // width = 1 / height = 1
   0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  // planes = 1 / bpp = 24
   0x01, 0x00, 0x18, 0x00,
]

///|
test "detect_supported_image_mime_type sniffs magic bytes" {
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(
      b"\xff\xd8\xff\xe0\x00\x10JFIF"[:],
    ),
    Some("image/jpeg"),
  )
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(test_png_bytes[:]),
    Some("image/png"),
  )
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(b"GIF89a\x01\x00\x01\x00"[:]),
    Some("image/gif"),
  )
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(
      b"RIFF\x24\x00\x00\x00WEBPVP8 "[:],
    ),
    Some("image/webp"),
  )
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(test_bmp_bytes[:]),
    Some("image/bmp"),
  )
}

///|
/// JPEG-XL 与 APNG 的魔数像支持的格式,但都被明确排除;普通文本返回 None。
test "detect_supported_image_mime_type rejects unsupported lookalikes" {
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(
      b"\xff\xd8\xff\xf7\x00\x00"[:],
    ),
    None,
  )
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(test_apng_bytes[:]),
    None,
  )
  assert_eq(@coding_agent.detect_supported_image_mime_type(b"hello"[:]), None)
  // BMP 的 planes/bpp 校验不通过时也不算图片。
  let bogus_bmp = test_bmp_bytes.to_array()
  bogus_bmp[26] = 2 // planes = 2
  assert_eq(
    @coding_agent.detect_supported_image_mime_type(
      Bytes::from_array(bogus_bmp)[:],
    ),
    None,
  )
}

///|
/// 文本参数变成 `<file>` 块;相对路径拼到 cwd 并做段规范化。
test "process_file_arguments inlines text files under <file> blocks" {
  let dir = @coding_agent.create_temp_dir("pim-attach-text-")
  @coding_agent.write_bytes_file(
    dir + "/note.txt",
    @utf8.encode("hello world\n"),
  )
  let result = @coding_agent.process_file_arguments(cwd=dir, [
    "./sub/../note.txt",
  ])
  assert_eq(result.images.length(), 0)
  assert_eq(
    result.text,
    "<file name=\"\{dir}/note.txt\">\nhello world\n\n</file>\n",
  )
  @coding_agent.remove_file(dir + "/note.txt")
  @coding_agent.remove_dir(dir)
}

///|
/// 图片参数进 `images`(base64 + mime),text 里只留空的 `<file>` 引用。
test "process_file_arguments attaches sniffed images inline" {
  let dir = @coding_agent.create_temp_dir("pim-attach-img-")
  @coding_agent.write_bytes_file(dir + "/pic.png", test_png_bytes)
  let result = @coding_agent.process_file_arguments(cwd=dir, ["pic.png"])
  assert_eq(result.text, "<file name=\"\{dir}/pic.png\"></file>\n")
  assert_eq(result.images.length(), 1)
  assert_eq(result.images[0].mime_type, "image/png")
  assert_eq(result.images[0].data, @base64.encode(test_png_bytes[:]))
  @coding_agent.remove_file(dir + "/pic.png")
  @coding_agent.remove_dir(dir)
}

///|
/// 不存在的路径、空文件和 `~` 展开三个边界行为。
test "process_file_arguments error and skip paths" {
  let dir = @coding_agent.create_temp_dir("pim-attach-edge-")
  // 不存在 → FsError,消息是裸文案(不带 FsError(...) 包装)。
  let missing = Ok(
    @coding_agent.process_file_arguments(cwd=dir, ["missing.txt"]),
  ) catch {
    e => Err(e)
  }
  guard missing is Err(err) else { fail("expected FsError for missing file") }
  assert_eq(err.to_string(), "File not found: \{dir}/missing.txt")
  // 空文件被跳过,不占 text 也不进 images。
  @coding_agent.write_bytes_file(dir + "/empty.txt", b"")
  let empty_only = @coding_agent.process_file_arguments(cwd=dir, ["empty.txt"])
  assert_eq(empty_only.text, "")
  assert_eq(empty_only.images.length(), 0)
  // 跳过的文件不影响后续 arg 的正常报错。
  let skipped = Ok(
    @coding_agent.process_file_arguments(cwd=dir, [
      "empty.txt", "also-missing.txt",
    ]),
  ) catch {
    e => Err(e)
  }
  guard skipped is Err(err2) else {
    fail("expected the second missing arg to fail")
  }
  assert_eq(err2.to_string(), "File not found: \{dir}/also-missing.txt")
  // `~`/`~/` 展开到 home 目录。
  let home = @coding_agent.home_dir()
  let tilde_path = home + "/pim-attach-tilde-7f3a9c.txt"
  @coding_agent.write_bytes_file(tilde_path, @utf8.encode("from home"))
  let expanded = @coding_agent.process_file_arguments(cwd=dir, [
    "~/pim-attach-tilde-7f3a9c.txt",
  ])
  assert_eq(
    expanded.text,
    "<file name=\"\{tilde_path}\">\nfrom home\n</file>\n",
  )
  @coding_agent.remove_file(tilde_path)
  @coding_agent.remove_file(dir + "/empty.txt")
  @coding_agent.remove_dir(dir)
}
