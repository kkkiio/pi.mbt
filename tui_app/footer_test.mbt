///|
extern "js" fn plain(value : String) -> String =
  #|(value) => value.replace(/\x1b\[[0-?]*[ -\/]*[@-~]/g, '')

///|
/// Capture the public TuiApp terminal output, without exposing Footer's renderer.
extern "js" fn capture_screen(width : Int, draw : () -> Unit) -> String =
  #| (width, draw) => {
  #|   const stdout = process.stdout, write = stdout.write;
  #|   const columns = Object.getOwnPropertyDescriptor(stdout, 'columns');
  #|   const rows = Object.getOwnPropertyDescriptor(stdout, 'rows');
  #|   let output = '';
  #|   try {
  #|     Object.defineProperty(stdout, 'columns', {value:width, configurable:true});
  #|     Object.defineProperty(stdout, 'rows', {value:24, configurable:true});
  #|     stdout.write = chunk => { output += String(chunk); return true; };
  #|     draw();
  #|     return output;
  #|   } finally {
  #|     stdout.write = write;
  #|     if (columns) Object.defineProperty(stdout, 'columns', columns); else delete stdout.columns;
  #|     if (rows) Object.defineProperty(stdout, 'rows', rows); else delete stdout.rows;
  #|   }
  #| }

///|
fn screen(app : @tui_app.TuiApp, width : Int) -> String {
  plain(capture_screen(width, fn() { app.tui.render_now(force=true) }))
}

///|
fn usage(
  input : Int,
  output : Int,
  read : Int,
  write : Int,
) -> @agent_loop.Usage {
  @agent_loop.Usage::{
    input,
    output,
    cache_read: read,
    cache_write: write,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: input + output + read + write,
    cost: @agent_loop.UsageCost::{
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    },
  }
}

///|
async test "footer accumulates usage and preserves assistant cache rate across tool usage" {
  let app = @tui_app.TuiApp::load("model", "/tmp", "high")
  defer {
    let _ = capture_screen(80, fn() { app.stop() })
  }
  let _ = capture_screen(80, fn() { app.start() })
  app.set_usage(usage(1000, 2, 1000, 0))
  app.set_usage(usage(999, 3, 0, 1), update_cache_hit=false)
  assert_true(screen(app, 80).contains("↑2.0k ↓5 R1.0k W1 CH50.0%"))
}

///|
async test "footer hides cache hit without cache totals and reset is instance-local" {
  let first = @tui_app.TuiApp::load("m", "/tmp", "high")
  defer {
    let _ = capture_screen(40, fn() { first.stop() })
  }
  let _ = capture_screen(40, fn() { first.start() })
  first.set_usage(usage(10, 0, 0, 0))
  assert_false(screen(first, 40).contains("CH"))
  first.reset_transcript()
  assert_false(screen(first, 40).contains("↑"))
  let second = @tui_app.TuiApp::load("m", "/tmp", "high")
  defer {
    let _ = capture_screen(40, fn() { second.stop() })
  }
  let _ = capture_screen(40, fn() { second.start() })
  assert_false(screen(second, 40).contains("↑"))
}

///|
async test "footer rounds boundaries, truncates right without ellipsis, and sanitizes labels" {
  let app = @tui_app.TuiApp::load("long-model-name", "/tmp", "high")
  defer {
    let _ = capture_screen(80, fn() { app.stop() })
  }
  let _ = capture_screen(80, fn() { app.start() })
  app.set_session_name(Some(" session\tname "))
  app.set_usage(usage(1999, 0, 0, 0))
  let wide = screen(app, 80)
  assert_true(wide.contains("/tmp • session name"))
  assert_true(wide.contains("↑2.0k"))
  app.reset_transcript()
  app.set_usage(usage(1999, 0, 0, 0))
  let narrow = screen(app, 12)
  assert_false(narrow.contains("..."))
  assert_true(narrow.contains("long-"))
}
