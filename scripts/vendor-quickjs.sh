#!/usr/bin/env bash
# vendor quickjs:下载固定版本的 QuickJS-NG 源码到 sdk/codemode/vendor/quickjs/。
#
# 版本与 tarball sha256 钉死在本文件里;升级时改 VERSION/SHA256 两个常量。
# 每次执行产出同一棵树 —— 入库文件以 git 为准,脚本只做获取与校验。
set -euo pipefail

VERSION=0.17.0
SHA256=559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/sdk/codemode/vendor/quickjs"
URL="https://github.com/quickjs-ng/quickjs/archive/refs/tags/v${VERSION}.tar.gz"

# moon.pkg native-stub 只编译这 4 个 .c;其余 .h 是它们的包含链(含
# 上游生成文件 builtin-*.h / libunicode-table.h)。新增文件须同步 moon.pkg。
FILES="
LICENSE
builtin-array-fromasync.h
builtin-iterator-zip-keyed.h
builtin-iterator-zip.h
cutils.h
dtoa.c
dtoa.h
libregexp-opcode.h
libregexp.c
libregexp.h
libunicode-table.h
libunicode.c
libunicode.h
list.h
quickjs-atom.h
quickjs-c-atomics.h
quickjs-opcode.h
quickjs.c
quickjs.h
"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "downloading $URL"
curl -fsSL -o "$tmpdir/quickjs.tar.gz" "$URL"

actual="$(shasum -a 256 "$tmpdir/quickjs.tar.gz" | awk '{print $1}')"
if [ "$actual" != "$SHA256" ]; then
  echo "error: sha256 mismatch" >&2
  echo "  expected: $SHA256" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi

tar -xzf "$tmpdir/quickjs.tar.gz" -C "$tmpdir"
src="$tmpdir/quickjs-$VERSION"

# 只落库白名单文件;目标目录里多余文件先清掉(版本升级瘦身)
mkdir -p "$DEST"
find "$DEST" -type f ! -name '.*' -delete
for f in $FILES; do
  cp "$src/$f" "$DEST/$f"
done

echo "vendored quickjs-ng v$VERSION -> sdk/codemode/vendor/quickjs ($(echo $FILES | wc -w | tr -d ' ') files)"
