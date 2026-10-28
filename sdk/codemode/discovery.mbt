///|
/// JavaScript globals for a codemode script host. This supplies discovery only;
/// the host owns script isolation, execution and the tools object.
#external
pub type DiscoveryGlobals

///|
/// Create ALL_TOOLS, searchTools(query, { limit?, namespace? }),
/// describeTool(name), and describeNamespace(name) for a JavaScript host to
/// inject into its script environment. The three functions return promises.
/// Reads the current registry at each call and never activates tools.
pub fn new_discovery_globals(
  registry : @tools.ToolRegistry,
) -> DiscoveryGlobals {
  make_globals(
    () => Json(registry.all_tools()).stringify(),
    (query, limit, ns, has_ns) => {
      Json(
        registry.search_tools(
          query,
          limit~,
          ns=if has_ns { Some(ns) } else { None },
        ),
      ).stringify()
    },
    name => {
      match registry.describe_tool(name) {
        Some(text) => Json::string(text).stringify()
        None => "null"
      }
    },
    name => {
      match registry.describe_namespace(name) {
        Some(text) => Json::string(text).stringify()
        None => "null"
      }
    },
  )
}

///|
extern "js" fn make_globals(
  all : () -> String,
  search : (String, Int32, String, Bool) -> String,
  describe_tool : (String) -> String,
  describe_ns : (String) -> String,
) -> DiscoveryGlobals =
  #| (all, search, describeTool, describeNamespace) => Object.freeze({
  #|   get ALL_TOOLS() { return JSON.parse(all()); },
  #|   async searchTools(query, { limit = 8, namespace } = {}) {
  #|     if (typeof query !== "string") throw new TypeError("query must be a string");
  #|     if (!Number.isInteger(limit) || limit <= 0 || limit > 2147483647) {
  #|       throw new TypeError("limit must be a positive integer");
  #|     }
  #|     if (namespace !== undefined && typeof namespace !== "string") {
  #|       throw new TypeError("namespace must be a string");
  #|     }
  #|     return JSON.parse(search(query, limit, namespace ?? "", namespace !== undefined));
  #|   },
  #|   async describeTool(name) {
  #|     if (typeof name !== "string") throw new TypeError("name must be a string");
  #|     return JSON.parse(describeTool(name)) ?? undefined;
  #|   },
  #|   async describeNamespace(name) {
  #|     if (typeof name !== "string") throw new TypeError("name must be a string");
  #|     return JSON.parse(describeNamespace(name)) ?? undefined;
  #|   },
  #| })
