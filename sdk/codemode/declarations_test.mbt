///|
/// pi test/declarations.test.ts 的移植(黑盒,快照)。
#warnings("-unused_async")
async fn dummy_execute(
  _args : Json?,
  _ctx : @codemode.CodemodeToolContext,
) -> Json? {
  None
}

///|
test "schema_to_type: primitives, literals, unions" {
  let cases : Array[Json] = [
    { "type": "string" },
    { "type": "integer" },
    { "type": ["string", "null"] },
    { "const": "a" },
    { "enum": ["a", 1, null] },
    { "anyOf": [{ "type": "string" }, { "type": "number" }] },
    { "anyOf": [{ "type": "string" }, {}] },
    {
      "allOf": [
        { "anyOf": [{ "type": "string" }, { "type": "number" }] },
        { "const": 1 },
      ],
    },
    { "$ref": "#/defs/x" },
  ]
  inspect(
    cases.map(fn(schema) { @codemode.schema_to_type(schema) }).join("\n"),
    content=(
      #|string
      #|number
      #|string | null
      #|"a"
      #|"a" | 1 | null
      #|string | number
      #|unknown
      #|(string | number) & 1
      #|unknown
    ),
  )
  inspect(
    @codemode.schema_to_type(Json(true)),
    content=(
      #|unknown
    ),
  )
  inspect(
    @codemode.schema_to_type(Json(false)),
    content=(
      #|never
    ),
  )
}

///|
test "schema_to_type: objects on one line, sorted properties" {
  let cases : Array[Json] = [
    {
      "type": "object",
      "properties": {
        "city": { "type": "string" },
        "max-lines": { "type": "number" },
      },
      "required": ["city"],
      "additionalProperties": false,
    },
    { "type": "object", "additionalProperties": { "type": "number" } },
    { "type": "object" },
    { "type": "object", "properties": {}, "additionalProperties": false },
  ]
  inspect(
    cases.map(fn(schema) { @codemode.schema_to_type(schema) }).join("\n---\n"),
    content=(
      #|{ city: string; "max-lines"?: number; }
      #|---
      #|{ [key: string]: number; }
      #|---
      #|{ [key: string]: unknown; }
      #|---
      #|{}
    ),
  )
}

///|
test "schema_to_type: property descriptions on comment lines" {
  let weather : Json = {
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
  }
  inspect(
    @codemode.schema_to_type(weather),
    content=(
      #|{
      #|  // look up weather for a given list of locations
      #|  weather: Array<{ location: string; }>;
      #|}
    ),
  )
  let nested : Json = {
    "type": "object",
    "properties": {
      "outer": {
        "type": "object",
        "description": "Outer",
        "properties": { "inner": { "type": "string", "description": "Inner" } },
      },
    },
  }
  inspect(
    @codemode.schema_to_type(nested),
    content=(
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
test "schema_to_type: constraints the type cannot express become tags" {
  let schema : Json = {
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
  }
  inspect(
    @codemode.schema_to_type(schema),
    content=(
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
test "schema_to_type: optional field constraints from the non-null branch" {
  let cases : Array[Json] = [
    {
      "type": "object",
      "properties": {
        "limit": {
          "anyOf": [
            { "type": "integer", "minimum": 1, "maximum": 100 },
            { "type": "null" },
          ],
          "default": null,
          "title": "Limit",
        },
      },
    },
    {
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
    },
  ]
  inspect(
    cases.map(fn(schema) { @codemode.schema_to_type(schema) }).join("\n---\n"),
    content=(
      #|{
      #|  // @integer @minimum 1 @maximum 100
      #|  limit?: number | null;
      #|}
      #|---
      #|{
      #|  // @integer @minimum 10 @maximum 20 @format port @format int32
      #|  n?: number | null;
      #|}
    ),
  )
}

///|
test "schema_to_type: draft-04 boolean exclusive bounds" {
  let schema : Json = {
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
  }
  inspect(
    @codemode.schema_to_type(schema),
    content=(
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
test "schema_to_type: long tags left out, line terminators escaped" {
  let long_text = "x".repeat(100)
  let cases : Array[Json] = [
    {
      "type": "object",
      "properties": {
        "config": { "type": "object", "default": { "text": long_text } },
      },
    },
    {
      "type": "object",
      "properties": {
        "sep": {
          "type": "string",
          "pattern": "^[\r\n\u2028\u2029]$",
          "default": "\u2028",
          "description": "a\u2028b",
        },
      },
    },
  ]
  inspect(
    cases.map(fn(schema) { @codemode.schema_to_type(schema) }).join("\n---\n"),
    content=(
      #|{ config?: { [key: string]: unknown; }; }
      #|---
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
test "schema_to_type: budget drops tags then falls back to unknown" {
  let schema : Json = {
    "type": "object",
    "properties": { "n": { "type": "integer", "minimum": 1 } },
  }
  inspect(
    [
      @codemode.schema_to_type(schema),
      @codemode.schema_to_type(schema, max_chars=Some(20)),
      @codemode.schema_to_type(schema, max_chars=Some(10)),
    ].join("\n---\n"),
    content=(
      #|{
      #|  // @integer @minimum 1
      #|  n?: number;
      #|}
      #|---
      #|{ n?: number; }
      #|---
      #|unknown
    ),
  )
}

///|
test "schema_to_type: local refs resolve, recursion and remote stop" {
  let schema : Json = {
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
  }
  inspect(
    @codemode.schema_to_type(schema),
    content=(
      #|{ item: { id: string; parent?: unknown; }; legacy?: "a" | "b"; remote?: unknown; }
    ),
  )
}

///|
test "schema_to_type: arrays and tuples" {
  let cases : Array[Json] = [
    { "type": "array", "items": { "type": "string" } },
    {
      "type": "array",
      "prefixItems": [{ "type": "string" }, { "type": "number" }],
    },
    { "type": "array" },
  ]
  inspect(
    cases.map(fn(schema) { @codemode.schema_to_type(schema) }).join("\n"),
    content=(
      #|Array<string>
      #|[string, number]
      #|unknown[]
    ),
  )
}

///|
test "schema_to_type: over-budget renders unknown" {
  let properties : Map[String, Json] = Map([])
  for i in 0..<50 {
    properties["field\{i}"] = ({ "type": "string" } : Json)
  }
  let schema : Json = { "type": "object", "properties": properties }
  assert_eq(@codemode.schema_to_type(schema, max_chars=Some(100)), "unknown")
  assert_true(@codemode.schema_to_type(schema).contains("field49?: string;"))
}

///|
test "render_tool_signature: normalized identifiers" {
  let tool = @codemode.CodemodeTool::new(
    name="hidden-dynamic-tool",
    execute=dummy_execute,
    input_schema=Some(
      (
        {
          "type": "object",
          "properties": { "city": { "type": "string" } },
          "required": ["city"],
          "additionalProperties": false,
        } : Json),
    ),
    output_schema=Some(
      (
        {
          "type": "object",
          "properties": { "ok": { "type": "boolean" } },
          "required": ["ok"],
        } : Json),
    ),
  )
  let free = @codemode.CodemodeTool::new(name="free", execute=dummy_execute)
  inspect(
    [
      @codemode.render_tool_signature(tool),
      @codemode.render_tool_signature(free),
    ].join("\n"),
    content=(
      #|hidden_dynamic_tool(args: { city: string; }): Promise<{ ok: boolean; }>;
      #|free(args: unknown): Promise<unknown>;
    ),
  )
}

///|
test "render_tool_signature: MCP CallToolResult-shaped output schema" {
  let tool = @codemode.CodemodeTool::new(
    name="plain",
    execute=dummy_execute,
    input_schema=Some(({ "type": "object", "properties": {} } : Json)),
    output_schema=Some(
      (
        {
          "type": "object",
          "properties": {
            "content": { "type": "array", "items": { "type": "object" } },
            "isError": { "type": "boolean" },
            "_meta": { "type": "object" },
          },
          "required": ["content"],
        } : Json),
    ),
  )
  inspect(
    @codemode.render_tool_signature(tool),
    content=(
      #|plain(args: { [key: string]: unknown; }): Promise<{ _meta?: { [key: string]: unknown; }; content: Array<{ [key: string]: unknown; }>; isError?: boolean; }>;
    ),
  )
}

///|
test "render_tool_sample: description plus declaration block" {
  let tool = @codemode.CodemodeTool::new(
    name="foo",
    description="bar",
    input_schema=Some(({ "type": "string" } : Json)),
    execute=dummy_execute,
  )
  inspect(
    @codemode.render_tool_sample(tool),
    content=(
      #|bar
      #|
      #|codemode tool declaration:
      #|```ts
      #|declare const tools: { foo(args: string): Promise<unknown>; };
      #|```
    ),
  )
}

///|
test "render_declarations: tools and globals" {
  inspect(
    @codemode.render_declarations(
      tools=[
        @codemode.CodemodeTool::new(
          name="read",
          description="Read a file.\nSecond line.",
          input_schema=Some(
            (
              {
                "type": "object",
                "properties": { "path": { "type": "string" } },
                "required": ["path"],
              } : Json),
          ),
          output_schema=Some(({ "type": "string" } : Json)),
          execute=dummy_execute,
        ),
        @codemode.CodemodeTool::new(name="remote-api", execute=dummy_execute),
      ],
      globals=[
        @codemode.CodemodeTool::new(
          name="attach",
          description="Attach it.",
          input_schema=Some(({ "type": "string" } : Json)),
          execute=dummy_execute,
        ),
      ],
    ),
    content=(
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
test "render_declarations: namespaced globals and explicit signatures" {
  inspect(
    @codemode.render_declarations(globals=[
      @codemode.CodemodeTool::new(
        name="models.list",
        description="List models.",
        signature=Some("(type: string): Promise<string[]>"),
        execute=dummy_execute,
      ),
      @codemode.CodemodeTool::new(
        name="models.get",
        input_schema=Some(({ "type": "string" } : Json)),
        execute=dummy_execute,
      ),
      @codemode.CodemodeTool::new(
        name="plain",
        signature=Some("(): void"),
        execute=dummy_execute,
      ),
    ]),
    content=(
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
test "render_declarations: comment terminators escaped in descriptions" {
  inspect(
    @codemode.render_declarations(tools=[
      @codemode.CodemodeTool::new(
        name="x",
        description="a */ b",
        execute=dummy_execute,
      ),
    ]),
    content=(
      #|declare const tools: {
      #|  /** a *\/ b */
      #|  x(args: unknown): Promise<unknown>;
      #|};
    ),
  )
}
