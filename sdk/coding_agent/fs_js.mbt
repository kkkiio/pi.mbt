///|
/// JavaScript (Node.js) file-system layer for `coding_agent`.
///
/// The package targets js only, so every operation here is a thin
/// synchronous wrapper over `node:fs` (plus `node:os` / `node:path` for the
/// temp directory). Two rules shape the FFI below:
///
/// - Throwing Node APIs are wrapped in JavaScript `try`/`catch` and return a
///   `{ ok, content }` record. A JS exception cannot be observed by MoonBit
///   `catch` (MoonBit errors are values, not JS exceptions), so the JS side
///   has to turn failures into data.
/// - Failures surface as `FsError` carrying Node's own message, which already
///   names the syscall and the path, e.g. `ENOENT: no such file or directory,
///   open '/x/y'`.
///
/// All operations are synchronous: the call sites are `async fn`s and the
/// payloads are small (project context files, one journal, chunked spill
/// writes), so there is nothing to gain from `node:fs/promises` plumbing.

///|
pub(all) suberror FsError {
  FsError(String)
} derive(Debug)

///|
pub extend FsError with @debug.Debug::{to_repr}

///|
pub impl Show for FsError with fn output(self, logger) {
  let FsError(message) = self
  logger.write_string(message)
}

///|
pub extend FsError with Show::{to_string, output}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

///|
/// Opaque handles for values that only exist inside JavaScript.
#external
priv type FsStats

///|
#external
priv type FsOptions

///|
/// The `{ ok, content }` record every wrapper below returns. `content` holds
/// the payload on success and Node's error message on failure, so the accessor
/// must match the operation that produced it.
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
extern "js" fn FsResult::as_int(self : FsResult) -> Int =
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
extern "js" fn open_sync(path : String, flags : String, mode : Int) -> Int = "openSync"

///|
#module("node:fs")
extern "js" fn write_sync(fd : Int, data : Bytes) -> Int = "writeSync"

///|
#module("node:fs")
extern "js" fn close_sync(fd : Int) -> Unit = "closeSync"

///|
#module("node:fs")
extern "js" fn mkdtemp_sync(prefix : String) -> String = "mkdtempSync"

///|
#module("node:os")
extern "js" fn os_tmpdir() -> String = "tmpdir"

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
  open : (String, String, Int) -> Int,
  path : String,
  flags : String,
  mode : Int,
) -> FsResult =
  #| function(open, path, flags, mode) {
  #|   try {
  #|     return { ok: true, content: open(path, flags, mode) };
  #|   } catch (error) {
  #|     return { ok: false, content: error.message };
  #|   }
  #| }

///|
/// `writeSync` may write fewer bytes than requested, so loop until the whole
/// chunk is on disk. A zero-byte write would spin forever, so treat it as an
/// error instead.
extern "js" fn write_all_ffi(
  write : (Int, Bytes) -> Int,
  fd : Int,
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

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

///|
/// Whether `path` exists. Never raises: this mirrors the previous native call
/// sites, which treated any error as "missing".
pub fn path_exists(path : String) -> Bool {
  exists_sync(path)
}

///|
/// Whether `path` is a regular file. Never raises: a missing path, an
/// unreadable path and a directory all report `false`.
pub fn is_regular_file(path : String) -> Bool {
  let res = is_regular_file_ffi(stat_sync, path)
  res.is_ok() && res.as_bool()
}

///|
/// Read a whole file as UTF-8 text. Malformed bytes raise `FsError`, matching
/// the strict `&Data::text()` decoding used by the previous implementation.
pub fn read_text_file(path : String) -> String raise FsError {
  let bytes = read_bytes_file(path)
  @utf8.decode(bytes) catch {
    _ => raise FsError("invalid UTF-8 in \{path}")
  }
}

///|
/// Read a whole file as raw bytes.
pub fn read_bytes_file(path : String) -> Bytes raise FsError {
  let res = read_file_ffi(read_file_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_bytes()
}

///|
/// Write bytes to `path`, replacing any existing file.
pub fn write_bytes_file(path : String, data : Bytes) -> Unit raise FsError {
  let res = write_file_ffi(write_file_sync, path, data)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// List the entry names of a directory (no hidden-file filtering and no
/// sorting: callers apply their own policy).
pub fn read_dir(path : String) -> FixedArray[String] raise FsError {
  let res = read_dir_ffi(read_dir_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_names()
}

///|
/// Create `path` and any missing parent directories.
pub fn create_dir(path : String) -> Unit raise FsError {
  let res = create_dir_ffi(mkdir_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// Remove a file.
pub fn remove_file(path : String) -> Unit raise FsError {
  let res = remove_file_ffi(unlink_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// Remove a directory and everything below it.
pub fn remove_dir(path : String) -> Unit raise FsError {
  let res = remove_dir_ffi(rm_sync, path)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// Create a fresh temporary directory under the system temp dir, prefixed with
/// `prefix`, and return its path. `mkdtempSync` creates it with mode 0700.
pub fn create_temp_dir(prefix : String) -> String raise FsError {
  let res = mkdtemp_ffi(mkdtemp_sync, path_join(os_tmpdir(), prefix))
  guard res.is_ok() else { raise FsError(res.as_message()) }
  res.as_string()
}

///|
/// A file opened for sequential writes: the bash tool's output spill file.
pub struct FsFile {
  fd : Int
}

///|
/// Open `path` for writing. `allow_existing=false` (the default) fails when
/// the file already exists, mirroring `@async/fs.create`.
pub fn create_file(
  path : String,
  allow_existing? : Bool = false,
  permission? : Int = 0o600,
) -> FsFile raise FsError {
  let flags = if allow_existing { "w" } else { "wx" }
  let res = open_file_ffi(open_sync, path, flags, permission)
  guard res.is_ok() else { raise FsError(res.as_message()) }
  { fd: res.as_int(), }
}

///|
/// Append `data` at the current write position.
pub fn FsFile::write_bytes(self : FsFile, data : Bytes) -> Unit raise FsError {
  let res = write_all_ffi(write_sync, self.fd, data)
  guard res.is_ok() else { raise FsError(res.as_message()) }
}

///|
/// `FsFile` writes sequentially, so one `write_once` always consumes the whole
/// slice (`write_bytes` loops internally because `writeSync` may write less).
#warnings("-unused_async")
pub impl @io.Writer for FsFile with fn write_once(
  self : FsFile,
  bytes : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  self.write_bytes(bytes[offset:offset + len].to_owned())
  len
}

///|
pub extend FsFile with @io.Writer::{write_once, write, write_reader}

///|
/// Close the file. Idempotent at the OS level is not guaranteed, so call it
/// once.
pub fn FsFile::close(self : FsFile) -> Unit {
  close_sync(self.fd)
}
