///|
/// pi wraps a compaction summary in these markers when it projects the summary
/// into the model context (`COMPACTION_SUMMARY_PREFIX` / `_SUFFIX`).
const COMPACTION_SUMMARY_PREFIX : String = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"

///|
const COMPACTION_SUMMARY_SUFFIX : String = "\n</summary>"
