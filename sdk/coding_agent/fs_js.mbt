///|
#derive(Debug)
pub(all) suberror FsError {
  FsError(String)
}

///|
pub extend FsError with @debug.Debug::{to_repr}

///|
pub impl Show for FsError with fn output(self, logger) {
  let FsError(message) = self
  logger.write_string(message)
}

///|
pub extend FsError with Show::{to_string, output}

///|
#external
priv type FsStats

///|
#external
priv type FsOptions

///|
#external
priv type FsResult

///|
extern "js" fn FsResult::is_ok(self : FsResult) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn FsResult::as_message(self : FsResult) -> String =
  #| (res) => res.content

///|
extern "js" fn FsResult::as_bool(self : FsResult) -> Bool =
  #| (res) => res.content

///|
extern "js" fn FsResult::as_int(self : FsResult) -> Int32 =
  #| (res) => res.content

///|
extern "js" fn FsResult::as_string(self : FsResult) -> String =
  #| (res) => res.content

///|
extern "js" fn FsResult::as_bytes(self : FsResult) -> Bytes =
  #| (res) => res.content

///|
extern "js" fn FsResult::as_names(self : FsResult) -> FixedArray[String] =
  #| (res) => res.content

///|
#module("node:fs")
extern "js" fn exists_sync(path : String) -> Bool = "existsSync"

///|
#module("node:fs")
extern "js" fn stat_sync(path : String) -> FsStats = "statSync"

///|
#module("node:fs")
extern "js" fn read_file_sync(path : String) -> Bytes = "readFileSync"

///|
#module("node:fs")
extern "js" fn write_file_sync(path : String, data : Bytes) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn read_dir_sync(path : String) -> FixedArray[String] = "readdirSync"

///|
#module("node:fs")
extern "js" fn mkdir_sync(path : String, options : FsOptions) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn unlink_sync(path : String) -> Unit = "unlinkSync"

///|
#module("node:fs")
extern "js" fn rm_sync(path : String, options : FsOptions) -> Unit = "rmSync"

///|
#module("node:fs")
extern "js" fn open_sync(path : String, flags : String, mode : Int32) -> Int32 = "openSync"

///|
#module("node:fs")
extern "js" fn write_sync(fd : Int32, data : Bytes) -> Int32 = "writeSync"

///|
#module("node:fs")
extern "js" fn close_sync(fd : Int32) -> Unit = "closeSync"

///|
#module("node:fs")
extern "js" fn mkdtemp_sync(prefix : String) -> String = "mkdtempSync"

///|
#module("node:os")
extern "js" fn os_tmpdir() -> String = "tmpdir"

///|
#module("node:os")
extern "js" fn os_homedir() -> String = "homedir"

///|
/// Returns the current user's home directory.
pub fn home_dir() -> String {
  os_homedir()
}

///|
#module("node:path")
extern "js" fn path_join(base : String, name : String) -> String = "join"

///|
extern "js" fn is_regular_file_ffi(
  stat : (String) -> FsStats,
  path : String,
) -> FsResult =
  #| function(stat, path) {
  #|   try {
  #|     return { ok: true, content: stat(path).isFile() };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn read_file_ffi(
  read_file : (String) -> Bytes,
  path : String,
) -> FsResult =
  #| function(readFile, path) {
  #|   try {
  #|     return { ok: true, content: readFile(path) };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn write_file_ffi(
  write_file : (String, Bytes) -> Unit,
  path : String,
  data : Bytes,
) -> FsResult =
  #| function(writeFile, path, data) {
  #|   try {
  #|     writeFile(path, data);
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn read_dir_ffi(
  read_dir : (String) -> FixedArray[String],
  path : String,
) -> FsResult =
  #| function(readDir, path) {
  #|   try {
  #|     return { ok: true, content: readDir(path) };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn create_dir_ffi(
  mkdir : (String, FsOptions) -> Unit,
  path : String,
) -> FsResult =
  #| function(mkdir, path) {
  #|   try {
  #|     mkdir(path, { recursive: true });
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn remove_file_ffi(
  unlink : (String) -> Unit,
  path : String,
) -> FsResult =
  #| function(unlink, path) {
  #|   try {
  #|     unlink(path);
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn remove_dir_ffi(
  rm : (String, FsOptions) -> Unit,
  path : String,
) -> FsResult =
  #| function(rm, path) {
  #|   try {
  #|     rm(path, { recursive: true });
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn open_file_ffi(
  open : (String, String, Int32) -> Int32,
  path : String,
  flags : String,
  mode : Int32,
) -> FsResult =
  #| function(open, path, flags, mode) {
  #|   try {
  #|     return { ok: true, content: open(path, flags, mode) };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn write_all_ffi(
  write : (Int32, Bytes) -> Int32,
  fd : Int32,
  data : Bytes,
) -> FsResult =
  #| function(write, fd, data) {
  #|   try {
  #|     let offset = 0;
  #|     while (offset < data.length) {
  #|       const written = write(fd, data.subarray(offset));
  #|       if (written <= 0) {
  #|         throw new Error("writeSync made no progress");
  #|       }
  #|       offset += written;
  #|     }
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
#module("node:fs")
extern "js" fn read_sync(
  fd : Int32,
  buffer : Bytes,
  offset : Int32,
  length : Int32,
  position : Double,
) -> Int32 = "readSync"

///|
extern "js" fn read_at_ffi(
  open : (String, String, Int32) -> Int32,
  read : (Int32, Bytes, Int32, Int32, Double) -> Int32,
  close : (Int32) -> Unit,
  path : String,
  position : Double,
  length : Int32,
) -> FsResult =
  #| function(open, read, close, path, position, length) {
  #|   try {
  #|     const fd = open(path, "r", 0);
  #|     try {
  #|       const buffer = new Uint8Array(length);
  #|       const n = read(fd, buffer, 0, length, position);
  #|       return { ok: true, content: buffer.subarray(0, n) };
  #|     } finally {
  #|       close(fd);
  #|     }
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn file_size_ffi(
  stat : (String) -> FsStats,
  path : String,
) -> FsResult =
  #| function(stat, path) {
  #|   try {
  #|     return { ok: true, content: stat(path).size };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
extern "js" fn FsResult::as_double(self : FsResult) -> Double =
  #| (res) => res.content

///|
extern "js" fn mkdtemp_ffi(
  mkdtemp : (String) -> String,
  prefix : String,
) -> FsResult =
  #| function(mkdtemp, prefix) {
  #|   try {
  #|     return { ok: true, content: mkdtemp(prefix) };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
/// Returns whether `path` exists.
pub fn path_exists(path : String) -> Bool {
  exists_sync(path)
}

///|
/// Returns whether `path` exists and is a regular file.
pub fn is_regular_file(path : String) -> Bool {
  let res = is_regular_file_ffi(stat_sync, path)
  res.is_ok() && res.as_bool()
}

///|
/// Reads a file as strict UTF-8 text; raises `FsError` on I/O failure or invalid UTF-8.
pub fn read_text_file(path : String) -> String raise FsError {
  let bytes = read_bytes_file(path)
  @utf8.decode(bytes) catch {
    _ => raise FsError("invalid UTF-8 in \{path}")
  }
}

///|
/// Reads a file as raw bytes.
pub fn read_bytes_file(path : String) -> Bytes raise FsError {
  let res = read_file_ffi(read_file_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_bytes()
}

///|
/// Reads up to `length` bytes of `path` starting at byte `position`.
pub fn read_file_at(
  path : String,
  position~ : Int64,
  length~ : Int32,
) -> Bytes raise FsError {
  let res = read_at_ffi(
    open_sync,
    read_sync,
    close_sync,
    path,
    position.to_double(),
    length,
  )
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_bytes()
}

///|
/// Returns the byte size of `path`.
pub fn file_size(path : String) -> Int64 raise FsError {
  let res = file_size_ffi(stat_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_double().to_int64()
}

///|
/// Writes `data` to `path`, replacing any existing file.
pub fn write_bytes_file(path : String, data : Bytes) -> Unit raise FsError {
  let res = write_file_ffi(write_file_sync, path, data)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
#module("node:fs")
extern "js" fn rename_sync(old_path : String, new_path : String) -> Unit = "renameSync"

///|
extern "js" fn rename_file_ffi(
  rename : (String, String) -> Unit,
  old_path : String,
  new_path : String,
) -> FsResult =
  #| function(rename, oldPath, newPath) {
  #|   try {
  #|     rename(oldPath, newPath);
  #|     return { ok: true, content: undefined };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
/// Atomically replaces `path` with `data` by staging to `path.tmp` with `permission` and renaming.
pub fn write_file_atomically(
  path : String,
  data : Bytes,
  permission~ : Int32 = 0o600,
) -> Unit raise FsError {
  let temp_path = "\{path}.tmp"
  let staged = create_file(temp_path, allow_existing=true, permission~) catch {
    err => raise FsError(err.to_string())
  }
  let written = try {
    staged.write_bytes(data)
    true
  } catch {
    _ => false
  }
  staged.close()
  guard written else {
    ignore(remove_file_ffi(unlink_sync, temp_path))
    raise FsError("failed to stage \{temp_path}")
  }
  let renamed = rename_file_ffi(rename_sync, temp_path, path)
  if !renamed.is_ok() {
    ignore(remove_file_ffi(unlink_sync, temp_path))
    raise FsError(renamed.as_message())
  }
}

///|
/// Lists entry names in directory `path`.
pub fn read_dir(path : String) -> FixedArray[String] raise FsError {
  let res = read_dir_ffi(read_dir_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_names()
}

///|
/// Creates directory `path` and any missing parent directories.
pub fn create_dir(path : String) -> Unit raise FsError {
  let res = create_dir_ffi(mkdir_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// Removes file `path`.
pub fn remove_file(path : String) -> Unit raise FsError {
  let res = remove_file_ffi(unlink_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// Recursively removes directory `path`.
pub fn remove_dir(path : String) -> Unit raise FsError {
  let res = remove_dir_ffi(rm_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// Creates a temporary directory under the system temp dir with `prefix` (mode 0700) and returns its path.
pub fn create_temp_dir(prefix : String) -> String raise FsError {
  let res = mkdtemp_ffi(mkdtemp_sync, path_join(os_tmpdir(), prefix))
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_string()
}

///|
/// File handle opened for sequential writes.
pub struct FsFile {
  fd : Int32
}

///|
/// Opens `path` for writing; fails when `allow_existing` is `false` and `path` already exists.
pub fn create_file(
  path : String,
  allow_existing~ : Bool = false,
  permission~ : Int32 = 0o600,
) -> FsFile raise FsError {
  let flags = if allow_existing { "w" } else { "wx" }
  let res = open_file_ffi(open_sync, path, flags, permission)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  { fd: res.as_int(), }
}

///|
/// Writes `data` at the current file position.
pub fn FsFile::write_bytes(self : FsFile, data : Bytes) -> Unit raise FsError {
  let res = write_all_ffi(write_sync, self.fd, data)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
#warnings("-unused_async")
pub impl @io.Writer for FsFile with fn write_once(
  self : FsFile,
  bytes : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  self.write_bytes(bytes[offset:offset + len].to_owned())
  len
}

///|
pub extend FsFile with @io.Writer::{write_once, write, write_reader}

///|
/// Closes the file descriptor.
pub fn FsFile::close(self : FsFile) -> Unit {
  close_sync(self.fd)
}

///|
/// Opens `path` for appending, creating it if absent without truncating existing content.
pub fn open_append_file(
  path : String,
  permission~ : Int32 = 0o600,
) -> FsFile raise FsError {
  let res = open_file_ffi(open_sync, path, "a", permission)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  { fd: res.as_int(), }
}

///|
/// Lazily opened file that defers creating or opening `path` until the first write.
pub struct LazyFile {
  path : String
  append : Bool
  permission : Int32
  mut file : FsFile?
}

///|
/// Creates a `LazyFile` at `path` (exclusive creation when `append=false`, append mode when `append=true`).
pub fn open_lazy_file(
  path : String,
  append~ : Bool = false,
  permission~ : Int32 = 0o600,
) -> LazyFile {
  { path, append, permission, file: None, }
}

///|
fn LazyFile::ensure_open(self : LazyFile) -> FsFile raise FsError {
  match self.file {
    Some(file) => file
    None => {
      let file = if self.append {
        open_append_file(self.path, permission=self.permission)
      } else {
        create_file(self.path, permission=self.permission)
      }
      self.file = Some(file)
      file
    }
  }
}

///|
/// Closes the underlying file if it was opened.
pub fn LazyFile::close(self : LazyFile) -> Unit {
  match self.file {
    Some(file) => file.close()
    None => ()
  }
  self.file = None
}

///|
#warnings("-unused_async")
pub impl @io.Writer for LazyFile with fn write_once(
  self : LazyFile,
  bytes : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let file = self.ensure_open()
  file.write_bytes(bytes[offset:offset + len].to_owned())
  len
}

///|
pub extend LazyFile with @io.Writer::{write_once, write, write_reader}
