///|
pub const CODEMODE_TOOL_NAME : String = @codemode_tool.CODEMODE_TOOL_NAME

///|
pub fn codemode_sidecar_path() -> String {
  match @env.get_env_var("PIM_CODEMODE_SIDECAR") {
    Some(path) if path.length() > 0 => path
    _ => default_codemode_sidecar_path()
  }
}

///|
extern "js" fn default_codemode_sidecar_path() -> String =
  #| () => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   const candidates = [
  #|     path.join(path.dirname(process.argv[1] ?? ""), "codemode-sidecar.mjs"),
  #|     path.join(process.cwd(), "scripts", "codemode-sidecar.mjs"),
  #|   ];
  #|   return candidates.find((p) => fs.existsSync(p)) ?? candidates[0];
  #| }

///|
fn spawn_codemode_sidecar(
  script : String,
) -> NdJsonStreams[SidecarStdout, SidecarStdin] {
  let process = SidecarProcess::spawn(script)
  let streams = NdJsonStreams::new(process.stdout, process.stdin)
  ignore(@js_async.Promise::from_async(() => streams.run() catch { _ => () }))
  streams
}

///|
pub fn new_codemode_tool_definition(
  tools~ : ArrayView[@tools.ToolDefinition],
  journal~ : &@agent_session.SessionJournal? = None,
  sidecar_path~ : String = codemode_sidecar_path(),
  timeout_ms~ : Int32 = 0,
  vm_launcher~ : (async () -> &@codemode.VmChannel)? = None,
) -> @tools.ToolDefinition {
  let launcher : async () -> &@codemode.VmChannel = match vm_launcher {
    Some(launcher) => launcher
    None => {
      let sidecar = @async.Lazy(() => spawn_codemode_sidecar(sidecar_path))
      async fn() -> &@codemode.VmChannel { sidecar.wait().new_stream() }
    }
  }
  @codemode_tool.new_codemode_tool_definition(
    launcher,
    tools~,
    journal~,
    timeout_ms~,
    write_temp_file=Some(fn(
      extension : String,
      data : Bytes,
    ) -> Result[String, String] {
      Ok(write_codemode_output_file(extension, data)) catch {
        error => Err(error.to_string())
      }
    }),
  )
}

///|
fn write_codemode_output_file(
  extension : String,
  data : Bytes,
) -> String raise FsError {
  let directory = create_temp_dir("pi-codemode-")
  let path = "\{directory}/output\{extension}"
  let file = create_file(path)
  defer file.close()
  file.write_bytes(data)
  path
}
