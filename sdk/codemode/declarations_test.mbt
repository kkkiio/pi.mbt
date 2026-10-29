///|
/// `CodemodeTool` needs an `execute`; declarations never call it.
fn declared_tool(
  name : String,
  description~ : String = "",
  input_schema~ : Json? = None,
  output_schema~ : Json? = None,
  signature~ : String? = None,
) -> @codemode.CodemodeTool {
  {
    name,
    js_name: None,
    description,
    input_schema,
    output_schema,
    spread: false,
    signature,
    execute: fn(_args : Json?) -> Json { Json::null() },
  }
}

///|
test "schema_to_type renders primitives, literals, and unions" {
  assert_eq(@codemode.schema_to_type({ "type": "string" }), "string")
  assert_eq(@codemode.schema_to_type({ "type": "integer" }), "number")
  assert_eq(
    @codemode.schema_to_type({ "type": ["string", "null"] }),
    "string | null",
  )
  assert_eq(@codemode.schema_to_type({ "const": "a" }), "\"a\"")
  assert_eq(
    @codemode.schema_to_type({ "enum": ["a", 1, Json::null()] }),
    "\"a\" | 1 | null",
  )
  assert_eq(
    @codemode.schema_to_type({
      "anyOf": [{ "type": "string" }, { "type": "number" }],
    }),
    "string | number",
  )
  assert_eq(
    @codemode.schema_to_type({ "anyOf": [{ "type": "string" }, {}] }),
    "unknown",
  )
  assert_eq(
    @codemode.schema_to_type({
      "allOf": [
        { "anyOf": [{ "type": "string" }, { "type": "number" }] },
        { "const": 1 },
      ],
    }),
    "(string | number) & 1",
  )
  assert_eq(@codemode.schema_to_type({ "$ref": "#/defs/x" }), "unknown")
  assert_eq(@codemode.schema_to_type(Json::boolean(true)), "unknown")
  assert_eq(@codemode.schema_to_type(Json::boolean(false)), "never")
}

///|
test "schema_to_type renders objects on one line with sorted properties" {
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "city": { "type": "string" },
        "max-lines": { "type": "number" },
      },
      "required": ["city"],
      "additionalProperties": false,
    }),
    "{ city: string; \"max-lines\"?: number; }",
  )
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "additionalProperties": { "type": "number" },
    }),
    "{ [key: string]: number; }",
  )
  assert_eq(
    @codemode.schema_to_type({ "type": "object" }),
    "{ [key: string]: unknown; }",
  )
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {},
      "additionalProperties": false,
    }),
    "{}",
  )
}

///|
test "schema_to_type puts property descriptions on comment lines" {
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "weather": {
          "type": "array",
          "description": "look up weather for a given list of locations",
          "items": {
            "type": "object",
            "properties": { "location": { "type": "string" } },
            "required": ["location"],
          },
        },
      },
      "required": ["weather"],
    }),
    (
      #|{
      #|  // look up weather for a given list of locations
      #|  weather: Array<{ location: string; }>;
      #|}
    ),
  )
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "outer": {
          "type": "object",
          "description": "Outer",
          "properties": {
            "inner": { "type": "string", "description": "Inner" },
          },
        },
      },
    }),
    (
      #|{
      #|  // Outer
      #|  outer?: {
      #|    // Inner
      #|    inner?: string;
      #|  };
      #|}
    ),
  )
}

///|
/// pi: constraints the type cannot express become `@tag value` comment lines.
test "schema_to_type puts constraints the type cannot express on comment lines" {
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "timeoutMs": {
          "type": "integer",
          "minimum": 0,
          "maximum": 30000,
          "default": 0,
          "description": "Wait in milliseconds.",
        },
        "id": { "type": "string", "pattern": "^[a-z]+$", "maxLength": 8 },
        "tags": {
          "type": "array",
          "items": { "type": "string" },
          "maxItems": 5,
          "uniqueItems": true,
          "deprecated": true,
        },
        "name": { "type": "string" },
      },
      "required": ["id"],
    }),
    (
      #|{
      #|  // @maxLength 8 @pattern ^[a-z]+$
      #|  id: string;
      #|  name?: string;
      #|  // @maxItems 5 @uniqueItems @deprecated
      #|  tags?: Array<string>;
      #|  // Wait in milliseconds.
      #|  // @integer @minimum 0 @maximum 30000 @default 0
      #|  timeoutMs?: number;
      #|}
    ),
  )
}

///|
/// pi: an optional field's constraints live in the anyOf non-null branch;
/// the branch's constraints apply together with the property's.
test "schema_to_type reads constraints of optional fields from the non-null branch" {
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "limit": {
          "anyOf": [
            { "type": "integer", "minimum": 1, "maximum": 100 },
            { "type": "null" },
          ],
          "default": Json::null(),
          "title": "Limit",
        },
      },
    }),
    (
      #|{
      #|  // @integer @minimum 1 @maximum 100
      #|  limit?: number | null;
      #|}
    ),
  )
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "n": {
          "anyOf": [
            {
              "type": "integer",
              "minimum": 10,
              "maximum": 50,
              "format": "int32",
            },
            { "type": "null" },
          ],
          "minimum": 0,
          "maximum": 20,
          "format": "port",
        },
      },
    }),
    (
      #|{
      #|  // @integer @minimum 10 @maximum 20 @format port @format int32
      #|  n?: number | null;
      #|}
    ),
  )
}

///|
/// pi: draft-04/OpenAPI 3.0 boolean `exclusiveMinimum`/`exclusiveMaximum`
/// move `minimum`/`maximum` into the exclusive tag.
test "schema_to_type reads draft-04 boolean exclusive bounds" {
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "n": {
          "type": "integer",
          "minimum": 0,
          "exclusiveMinimum": true,
          "maximum": 10,
          "exclusiveMaximum": false,
        },
        "m": {
          "anyOf": [
            { "type": "number", "maximum": 5, "exclusiveMaximum": true },
            { "type": "null" },
          ],
          "maximum": 8,
        },
      },
    }),
    (
      #|{
      #|  // @maximum 8 @exclusiveMaximum 5
      #|  m?: number | null;
      #|  // @integer @exclusiveMinimum 0 @maximum 10
      #|  n?: number;
      #|}
    ),
  )
}

///|
/// pi: tags longer than 80 chars are left out; line terminators inside a tag
/// are escaped as `\uXXXX`.
test "schema_to_type leaves out long tags and escapes line terminators" {
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "config": { "type": "object", "default": { "text": "x".repeat(100) } },
      },
    }),
    "{ config?: { [key: string]: unknown; }; }",
  )
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "sep": {
          "type": "string",
          "pattern": "^[\r\n\u2028\u2029]$",
          "default": "\u2028",
          "description": "a\u2028b",
        },
      },
    }),
    (
      #|{
      #|  // a
      #|  // b
      #|  // @pattern ^[\u000d\u000a\u2028\u2029]$ @default "\u2028"
      #|  sep?: string;
      #|}
    ),
  )
}

///|
/// pi: over `max_chars` the render retries without constraint tags, then
/// becomes `unknown` when still too long.
test "schema_to_type drops constraint tags before rendering a type over the budget as unknown" {
  let schema : Json = {
    "type": "object",
    "properties": { "n": { "type": "integer", "minimum": 1 } },
  }
  assert_eq(
    @codemode.schema_to_type(schema),
    (
      #|{
      #|  // @integer @minimum 1
      #|  n?: number;
      #|}
    ),
  )
  assert_eq(
    @codemode.schema_to_type(schema, max_chars=Some(20)),
    "{ n?: number; }",
  )
  assert_eq(@codemode.schema_to_type(schema, max_chars=Some(10)), "unknown")
}

///|
/// pi: local `#/$defs/...`/`#/definitions/...` resolve; remote, missing and
/// recursive references render `unknown`.
test "schema_to_type resolves local references and stops at recursive ones" {
  assert_eq(
    @codemode.schema_to_type({
      "type": "object",
      "properties": {
        "item": { "$ref": "#/$defs/Item" },
        "legacy": { "$ref": "#/definitions/Legacy" },
        "remote": { "$ref": "https://example.com/schema.json" },
      },
      "required": ["item"],
      "$defs": {
        "Item": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "parent": { "$ref": "#/$defs/Item" },
          },
          "required": ["id"],
        },
      },
      "definitions": { "Legacy": { "enum": ["a", "b"] } },
    }),
    "{ item: { id: string; parent?: unknown; }; legacy?: \"a\" | \"b\"; remote?: unknown; }",
  )
}

///|
/// pi: more than 32 local `$ref` expansions per schema renders `unknown`
/// for the later references.
test "schema_to_type caps local reference expansions" {
  let defs : Map[String, Json] = Map([])
  let properties : Map[String, Json] = Map([])
  for i in 0..<34 {
    defs["d\{i}"] = { "type": "string" }
    properties["p\{i}"] = { "$ref": "#/$defs/d\{i}" }
  }
  let result = @codemode.schema_to_type({
    "type": "object",
    "properties": Json(properties),
    "$defs": Json(defs),
  })
  // The first 32 expand to `string`; the remaining two become `unknown`.
  assert_eq(
    result, "{ p0?: string; p1?: string; p10?: string; p11?: string; p12?: string; p13?: string; p14?: string; p15?: string; p16?: string; p17?: string; p18?: string; p19?: string; p2?: string; p20?: string; p21?: string; p22?: string; p23?: string; p24?: string; p25?: string; p26?: string; p27?: string; p28?: string; p29?: string; p3?: string; p30?: string; p31?: string; p32?: string; p33?: string; p4?: string; p5?: string; p6?: string; p7?: string; p8?: unknown; p9?: unknown; }",
  )
}

///|
test "schema_to_type renders arrays and tuples" {
  assert_eq(
    @codemode.schema_to_type({ "type": "array", "items": { "type": "string" } }),
    "Array<string>",
  )
  assert_eq(
    @codemode.schema_to_type({
      "type": "array",
      "prefixItems": [{ "type": "string" }, { "type": "number" }],
    }),
    "[string, number]",
  )
  assert_eq(@codemode.schema_to_type({ "type": "array" }), "unknown[]")
}

///|
test "schema_to_type renders types over the budget as unknown" {
  let properties : Map[String, Json] = Map([])
  for i in 0..<50 {
    properties["field\{i}"] = { "type": "string" }
  }
  let schema : Json = { "type": "object", "properties": Json(properties) }
  assert_eq(@codemode.schema_to_type(schema, max_chars=Some(100)), "unknown")
  assert_true(@codemode.schema_to_type(schema).contains("field49?: string;"))
}

///|
/// pi: the signature uses `toCodemodeIdentifier(name)` — not `jsName`.
test "render_tool_signature renders signatures with normalized identifiers" {
  assert_eq(
    @codemode.render_tool_signature(
      declared_tool(
        "hidden-dynamic-tool",
        input_schema=Some({
          "type": "object",
          "properties": { "city": { "type": "string" } },
          "required": ["city"],
          "additionalProperties": false,
        }),
        output_schema=Some({
          "type": "object",
          "properties": { "ok": { "type": "boolean" } },
          "required": ["ok"],
        }),
      ),
    ),
    "hidden_dynamic_tool(args: { city: string; }): Promise<{ ok: boolean; }>;",
  )
  assert_eq(
    @codemode.render_tool_signature(declared_tool("free")),
    "free(args: unknown): Promise<unknown>;",
  )
}

///|
test "render_tool_signature renders output schemas shaped like an MCP CallToolResult as plain types" {
  assert_eq(
    @codemode.render_tool_signature(
      declared_tool(
        "plain",
        input_schema=Some({ "type": "object", "properties": {} }),
        output_schema=Some({
          "type": "object",
          "properties": {
            "content": { "type": "array", "items": { "type": "object" } },
            "isError": { "type": "boolean" },
            "_meta": { "type": "object" },
          },
          "required": ["content"],
        }),
      ),
    ),
    "plain(args: { [key: string]: unknown; }): Promise<{ _meta?: { [key: string]: unknown; }; content: Array<{ [key: string]: unknown; }>; isError?: boolean; }>;",
  )
}

///|
test "render_tool_sample renders the per-tool sample" {
  assert_eq(
    @codemode.render_tool_sample(
      declared_tool(
        "foo",
        description="bar",
        input_schema=Some({ "type": "string" }),
      ),
    ),
    "bar\n\ncodemode tool declaration:\n```ts\ndeclare const tools: { foo(args: string): Promise<unknown>; };\n```",
  )
}

///|
test "render_declarations renders tools and globals" {
  let text = @codemode.render_declarations(
    tools=[
      declared_tool(
        "read",
        description="Read a file.\nSecond line.",
        input_schema=Some({
          "type": "object",
          "properties": { "path": { "type": "string" } },
          "required": ["path"],
        }),
        output_schema=Some({ "type": "string" }),
      ),
      declared_tool("remote-api"),
    ],
    globals=[
      declared_tool(
        "attach",
        description="Attach it.",
        input_schema=Some({ "type": "string" }),
      ),
    ],
  )
  assert_eq(
    text,
    (
      #|declare const tools: {
      #|  /**
      #|   * Read a file.
      #|   * Second line.
      #|   */
      #|  read(args: { path: string; }): Promise<string>;
      #|  remote_api(args: unknown): Promise<unknown>;
      #|};
      #|
      #|/** Attach it. */
      #|declare function attach(args: string): Promise<unknown>;
    ),
  )
}

///|
/// pi: `ns.member` globals become `declare const ns` members; a `signature`
/// replaces the schema rendering.
test "render_declarations renders namespaced globals and explicit signatures" {
  let text = @codemode.render_declarations(globals=[
    declared_tool(
      "models.list",
      description="List models.",
      signature=Some("(type: string): Promise<string[]>"),
    ),
    declared_tool("models.get", input_schema=Some({ "type": "string" })),
    declared_tool("plain", signature=Some("(): void")),
  ])
  assert_eq(
    text,
    (
      #|declare function plain(): void;
      #|
      #|declare const models: {
      #|  /** List models. */
      #|  list(type: string): Promise<string[]>;
      #|  get(args: string): Promise<unknown>;
      #|};
    ),
  )
}

///|
/// pi: `*/` inside a description is escaped so it cannot end the doc comment.
test "render_declarations escapes comment terminators in descriptions" {
  let text = @codemode.render_declarations(tools=[
    declared_tool("x", description="a */ b"),
  ])
  assert_true(text.contains("/** a *\\/ b */"))
}
