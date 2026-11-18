///|
/// A provider-executed call reported by the assistant.
#derive(Debug, ToJson, FromJson)
pub(all) enum HostedToolCall {
  WebSearch(WebSearchCall)
}

///|
/// Search activity and its outcome, keyed by the provider's item ID.
#derive(Debug, ToJson, FromJson)
pub(all) struct WebSearchCall {
  id : String
  status : String
  action : WebSearchAction
  error_code : String?
}

///|
/// Action taken by the search tool. Missing sources indicate that the provider omitted them.
#derive(Debug, ToJson, FromJson)
pub(all) enum WebSearchAction {
  Search(queries~ : Array[String], sources~ : Array[WebSearchSource]?)
  OpenPage(url~ : String)
  FindInPage(url~ : String, pattern~ : String)
  Unknown
}

///|
/// Display metadata for one search result.
#derive(Debug, ToJson, FromJson)
pub(all) struct WebSearchSource {
  url : String
  title : String?
  snippet : String?
  published_at : String?
}

///|
pub extend WebSearchCall with ToJson::{to_json}
