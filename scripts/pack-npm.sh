#!/usr/bin/env bash
# Build the npm dist at the repo root (the repo root is the npm package root):
# `moon build --target js --release`, then copy the bundle to dist/pim.js with a
# node shebang so the root package.json `bin` entry is directly executable.
# pi-tui is resolved from node_modules (a declared dependency), not bundled here.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

moon build --target js --release

dist="dist"
rm -rf "$dist"
mkdir -p "$dist"
{
  printf '#!/usr/bin/env node\n'
  cat "_build/js/release/build/cmd/pim/pim.js"
} > "$dist/pim.js"
chmod +x "$dist/pim.js"

# Smoke the packaged entry exactly as npm will run it.
"$dist/pim.js" --help > /dev/null
echo "packed $dist/pim.js ($(wc -c < "$dist/pim.js") bytes)"
