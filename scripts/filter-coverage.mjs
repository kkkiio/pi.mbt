// Remove excluded paths from a Coveralls-format coverage.json, in place.
// Usage: node scripts/filter-coverage.mjs coverage.json
import { readFileSync, writeFileSync } from "node:fs";

const file = process.argv[2];
const json = JSON.parse(readFileSync(file, "utf8"));
const keep = json.source_files.filter(
  (f) => !/^(examples|cmd)\//.test(f.name),
);
console.log(
  `coverage: dropped ${json.source_files.length - keep.length} source files, kept ${keep.length}`,
);
json.source_files = keep;
writeFileSync(file, JSON.stringify(json));
