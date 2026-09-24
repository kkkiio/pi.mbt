#!/usr/bin/env bash
# Build the publishable npm package for cmd/pim: moon build --target js, then
# wrap the bundle with a node shebang so the `bin` entry is directly
# executable. The runtime needs nothing but node builtins.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

moon build --target js --release

dist="cmd/pim/dist"
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
