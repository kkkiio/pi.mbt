///|
pub(all) struct TruncationResult {
  content : String
  truncated : Bool
  truncated_by : String?
  total_lines : Int
  total_bytes : Int
  output_lines : Int
  output_bytes : Int
  last_line_partial : Bool
  first_line_exceeds_limit : Bool
  max_lines : Int
  max_bytes : Int
} derive(Eq, @debug.Debug, ToJson)

///|
pub(all) struct OutputSnapshot {
  content : String
  truncation : TruncationResult
  full_output_path : String?
} derive(Eq, @debug.Debug, ToJson)

///|
/// Incrementally tracks streaming output with bounded memory.
///
/// Input is decoded as a continuous UTF-8 stream. Display snapshots retain
/// only a rolling tail, while output that exceeds either limit is preserved in
/// a temporary file as its original bytes.
pub struct OutputAccumulator {
  max_lines : Int
  max_bytes : Int
  max_rolling_bytes : Int
  temp_file_prefix : String
  raw_chunks : Array[Bytes]
  mut tail : Bytes
  mut tail_starts_at_line_boundary : Bool
  mut pending_utf8 : Bytes
  mut decoder_started : Bool
  mut total_raw_bytes : Int
  mut total_decoded_bytes : Int
  mut completed_lines : Int
  mut total_lines : Int
  mut current_line_bytes : Int
  mut has_open_line : Bool
  mut finished : Bool
  mut temp_file_path : String?
  mut temp_file : OutputFile?
}

///|
struct OutputFile {
  file : @fs.File
}

///|
async fn create_temp_output_file(prefix : String) -> (String, OutputFile) {
  let directory = @fs.tmpdir(prefix~)
  let path = "\{directory}/output.log"
  let file = @fs.create(path, allow_existing=false, permission=0o600)
  (path, { file, })
}

///|
async fn OutputFile::write(self : OutputFile, data : Bytes) -> Unit {
  self.file.write(data)
}

///|
fn OutputFile::close(self : OutputFile) -> Unit {
  self.file.close()
}

///|
pub fn OutputAccumulator::OutputAccumulator(
  max_lines~ : Int,
  max_bytes~ : Int,
  max_rolling_bytes? : Int = @cmp.maximum(max_bytes * 2, 1),
  temp_file_prefix? : String = "pim-output",
) -> OutputAccumulator {
  {
    max_lines,
    max_bytes,
    max_rolling_bytes,
    temp_file_prefix,
    raw_chunks: [],
    tail: b"",
    tail_starts_at_line_boundary: true,
    pending_utf8: b"",
    decoder_started: false,
    total_raw_bytes: 0,
    total_decoded_bytes: 0,
    completed_lines: 0,
    total_lines: 0,
    current_line_bytes: 0,
    has_open_line: false,
    finished: false,
    temp_file_path: None,
    temp_file: None,
  }
}

///|
pub async fn OutputAccumulator::append(
  self : OutputAccumulator,
  data : BytesView,
) -> Unit {
  if self.finished {
    fail("Cannot append to a finished output accumulator")
  }
  let chunk = data.to_owned()
  self.total_raw_bytes += chunk.length()
  let input = self.pending_utf8 + chunk
  let mut decode_end = input.length()
  if !input.is_empty() {
    let mut index = input.length() - 1
    let mut continuation_bytes = 0
    while index >= 0 && continuation_bytes < 3 {
      let byte = input[index].to_int()
      if (byte & 0xc0) != 0x80 {
        break
      }
      continuation_bytes += 1
      index -= 1
    }
    if index >= 0 {
      let leading = input[index].to_int()
      let expected = if leading >= 0xc2 && leading <= 0xdf {
        2
      } else if leading >= 0xe0 && leading <= 0xef {
        3
      } else if leading >= 0xf0 && leading <= 0xf4 {
        4
      } else {
        0
      }
      if expected > input.length() - index {
        decode_end = index
      }
    }
  }
  self.pending_utf8 = input[decode_end:].to_owned()
  if decode_end > 0 {
    let decoded = @utf8.decode_lossy(
      input[:decode_end],
      ignore_bom=self.decoder_started,
    )
    self.decoder_started = true
    let decoded_bytes = @utf8.encode(decoded)
    self.total_decoded_bytes += decoded_bytes.length()
    self.tail = self.tail + decoded_bytes
    let mut newline_count = 0
    let mut last_newline = -1
    for i, byte in decoded_bytes {
      if byte == b'\n' {
        newline_count += 1
        last_newline = i
      }
    }
    if newline_count == 0 {
      self.current_line_bytes += decoded_bytes.length()
      self.has_open_line = true
    } else {
      self.completed_lines += newline_count
      self.current_line_bytes = decoded_bytes.length() - last_newline - 1
      self.has_open_line = self.current_line_bytes > 0
    }
    self.total_lines = self.completed_lines +
      (if self.has_open_line { 1 } else { 0 })
    if self.tail.length() > self.max_rolling_bytes * 2 {
      let mut start = self.tail.length() - self.max_rolling_bytes
      while start < self.tail.length() &&
            (self.tail[start].to_int() & 0xc0) == 0x80 {
        start += 1
      }
      self.tail_starts_at_line_boundary = if start == 0 {
        self.tail_starts_at_line_boundary
      } else {
        self.tail[start - 1] == b'\n'
      }
      self.tail = self.tail[start:].to_owned()
    }
  }
  let exceeded = self.total_raw_bytes > self.max_bytes ||
    self.total_decoded_bytes > self.max_bytes ||
    self.total_lines > self.max_lines
  match self.temp_file {
    Some(file) => file.write(chunk)
    None if exceeded => {
      self.ensure_temp_file()
      guard self.temp_file is Some(file) else {
        abort("temporary file was not created")
      }
      file.write(chunk)
    }
    None if !chunk.is_empty() => self.raw_chunks.push(chunk)
    None => ()
  }
}

///|
pub async fn OutputAccumulator::finish(self : OutputAccumulator) -> Unit {
  guard !self.finished else { return }
  self.finished = true
  if !self.pending_utf8.is_empty() {
    let decoded = @utf8.decode_lossy(
      self.pending_utf8,
      ignore_bom=self.decoder_started,
    )
    self.decoder_started = true
    self.pending_utf8 = b""
    let decoded_bytes = @utf8.encode(decoded)
    self.total_decoded_bytes += decoded_bytes.length()
    self.tail = self.tail + decoded_bytes
    let mut newline_count = 0
    let mut last_newline = -1
    for i, byte in decoded_bytes {
      if byte == b'\n' {
        newline_count += 1
        last_newline = i
      }
    }
    if newline_count == 0 {
      self.current_line_bytes += decoded_bytes.length()
      self.has_open_line = true
    } else {
      self.completed_lines += newline_count
      self.current_line_bytes = decoded_bytes.length() - last_newline - 1
      self.has_open_line = self.current_line_bytes > 0
    }
    self.total_lines = self.completed_lines +
      (if self.has_open_line { 1 } else { 0 })
    if self.tail.length() > self.max_rolling_bytes * 2 {
      let mut start = self.tail.length() - self.max_rolling_bytes
      while start < self.tail.length() &&
            (self.tail[start].to_int() & 0xc0) == 0x80 {
        start += 1
      }
      self.tail_starts_at_line_boundary = if start == 0 {
        self.tail_starts_at_line_boundary
      } else {
        self.tail[start - 1] == b'\n'
      }
      self.tail = self.tail[start:].to_owned()
    }
  }
  if self.total_raw_bytes > self.max_bytes ||
    self.total_decoded_bytes > self.max_bytes ||
    self.total_lines > self.max_lines {
    self.ensure_temp_file()
  }
}

///|
pub async fn OutputAccumulator::snapshot(
  self : OutputAccumulator,
  persist_if_truncated? : Bool = false,
) -> OutputSnapshot {
  let mut snapshot_bytes = self.tail
  if !self.tail_starts_at_line_boundary {
    match snapshot_bytes.find(b"\n") {
      Some(first_newline) =>
        snapshot_bytes = snapshot_bytes[first_newline + 1:].to_owned()
      None => ()
    }
  }
  let snapshot_text = @utf8.decode(snapshot_bytes)
  let lines : Array[StringView] = if snapshot_text.is_empty() {
    []
  } else {
    snapshot_text.split("\n").to_array()
  }
  if snapshot_text.has_suffix("\n") {
    ignore(lines.pop())
  }
  let snapshot_total_bytes = snapshot_bytes.length()
  let snapshot_total_lines = lines.length()
  let candidate_needs_truncation = snapshot_total_lines > self.max_lines ||
    snapshot_total_bytes > self.max_bytes
  let output_lines : Array[String] = []
  let mut output_bytes_count = 0
  let mut truncated_by : String? = None
  let mut last_line_partial = false
  if candidate_needs_truncation {
    for i = lines.length() - 1
        i >= 0 && output_lines.length() < self.max_lines
        i = i - 1 {
      let line = lines[i]
      let line_bytes = @utf8.encode(line)
      let separator_bytes = if output_lines.is_empty() { 0 } else { 1 }
      if output_bytes_count + line_bytes.length() + separator_bytes >
        self.max_bytes {
        truncated_by = Some("bytes")
        if output_lines.is_empty() {
          let mut start = @cmp.maximum(line_bytes.length() - self.max_bytes, 0)
          while start < line_bytes.length() &&
                (line_bytes[start].to_int() & 0xc0) == 0x80 {
            start += 1
          }
          let partial = @utf8.decode(line_bytes[start:])
          output_lines.push(partial)
          output_bytes_count = line_bytes.length() - start
          last_line_partial = true
        }
        break
      }
      output_lines.push(line.to_owned())
      output_bytes_count += line_bytes.length() + separator_bytes
    }
    output_lines.rev_in_place()
    if output_lines.length() >= self.max_lines &&
      output_bytes_count <= self.max_bytes {
      truncated_by = Some("lines")
    }
  } else {
    for line in lines {
      output_lines.push(line.to_owned())
    }
    output_bytes_count = snapshot_total_bytes
  }
  let content = if candidate_needs_truncation {
    output_lines.join("\n")
  } else {
    snapshot_text
  }
  let truncated = self.total_lines > self.max_lines ||
    self.total_decoded_bytes > self.max_bytes
  if truncated && truncated_by is None {
    truncated_by = Some(
      if self.total_decoded_bytes > self.max_bytes {
        "bytes"
      } else {
        "lines"
      },
    )
  }
  let truncation = TruncationResult::{
    content,
    truncated,
    truncated_by,
    total_lines: self.total_lines,
    total_bytes: self.total_decoded_bytes,
    output_lines: output_lines.length(),
    output_bytes: if candidate_needs_truncation {
      @utf8.encode(content).length()
    } else {
      output_bytes_count
    },
    last_line_partial,
    first_line_exceeds_limit: false,
    max_lines: self.max_lines,
    max_bytes: self.max_bytes,
  }
  if persist_if_truncated && truncated {
    self.ensure_temp_file()
  }
  { content, truncation, full_output_path: self.temp_file_path }
}

///|
pub fn OutputAccumulator::close_temp_file(self : OutputAccumulator) -> Unit {
  match self.temp_file {
    None => ()
    Some(file) => {
      self.temp_file = None
      file.close()
    }
  }
}

///|
pub fn OutputAccumulator::get_last_line_bytes(self : OutputAccumulator) -> Int {
  self.current_line_bytes
}

///|
#warnings("-unused_async")
async fn OutputAccumulator::ensure_temp_file(self : OutputAccumulator) -> Unit {
  guard self.temp_file_path is None else { return }
  let (path, file) = create_temp_output_file(self.temp_file_prefix)
  for chunk in self.raw_chunks {
    file.write(chunk)
  }
  self.raw_chunks.clear()
  self.temp_file_path = Some(path)
  self.temp_file = Some(file)
}
