///|
pub const CODEMODE_TOOL_NAME : String = @codemode_tool.CODEMODE_TOOL_NAME

///|
pub fn new_codemode_tool_definition(
  streams : WsStreams,
  tools~ : ArrayView[@tools.ToolDefinition],
  journal~ : &@agent_session.SessionJournal? = None,
  timeout_ms~ : Int32 = 0,
  write_temp_file~ : @codemode_tool.TempFileWriter? = None,
) -> @tools.ToolDefinition {
  @codemode_tool.new_codemode_tool_definition(
    fn() -> &@codemode.VmChannel { streams.new_stream() },
    tools~,
    journal~,
    timeout_ms~,
    write_temp_file~,
  )
}
