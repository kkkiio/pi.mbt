///|
fn decode_web_search_call(item : Json) -> @agent_loop.AssistantMessageContent? {
  guard item is { "id": String(id), .. } else { return None }
  let status = match item {
    { "status": String(status), .. } => status
    _ => "unknown"
  }
  let error_code = match item {
    { "error": { "code": String(code), .. }, .. } => Some(code)
    _ => None
  }
  let action : @agent_loop.WebSearchAction = match item {
    { "action": { "type": "search", .. } as action, .. } => {
      let queries = match action {
        { "queries": Array(queries), .. } =>
          queries.filter_map(query => {
            match query {
              String(text) => Some(text)
              _ => None
            }
          })
        { "query": String(query), .. } => [query]
        _ => []
      }
      let sources = match action {
        { "sources": Array(sources), .. } =>
          Some(sources.filter_map(decode_web_search_source))
        _ => None
      }
      Search(queries~, sources~)
    }
    { "action": { "type": "open_page", "url": String(url), .. }, .. } =>
      OpenPage(url~)
    {
      "action": {
        "type": "find_in_page",
        "url": String(url),
        "pattern": String(pattern),
        ..
      },
      ..
    } => FindInPage(url~, pattern~)
    _ => Unknown
  }
  Some(
    @agent_loop.AssistantMessageContent::HostedToolCall(
      WebSearch({ id, status, action, error_code, }),
      signature=item,
    ),
  )
}

///|
fn decode_web_search_source(source : Json) -> @agent_loop.WebSearchSource? {
  guard source is { "url": String(url), .. } else { return None }
  let title = match source {
    { "title": String(value), .. } => Some(value)
    _ => None
  }
  let snippet = match source {
    { "snippet": String(value), .. } => Some(value)
    _ => None
  }
  let published_at = match source {
    { "published_at": String(value), .. } => Some(value)
    _ => None
  }
  Some({ url, title, snippet, published_at, })
}
