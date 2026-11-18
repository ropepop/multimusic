#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'This verified signing workflow requires macOS.' >&2
  exit 2
fi
for dependency in git make pkg-config python3 xcrun; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 2; }
done
if ! pkg-config --exists openssl; then
  echo 'Install OpenSSL development libraries and pkg-config; for Homebrew: brew install pkg-config openssl.' >&2
  exit 2
fi
compiler=$(xcrun --find clang++)
c_compiler=$(xcrun --find clang)
sdk=$(xcrun --sdk macosx --show-sdk-path)
commit=614caa8d1ca949e260e5746144aa52d27a4b08d6
mkdir -p build/tools
stage=$(mktemp -d "$PWD/build/tools/zsign-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
git init --quiet "$stage/source"
git -C "$stage/source" fetch --quiet --depth=1 https://github.com/zhlynn/zsign "$commit"
git -C "$stage/source" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$stage/source" rev-parse HEAD)" = "$commit"
git -C "$stage/source" diff --quiet HEAD
if ! make -C "$stage/source/build/macos" -j2 "CXX=\"$compiler\" -isysroot \"$sdk\"" "CC=\"$c_compiler\" -isysroot \"$sdk\"" VERSION=1.1.2 >"$stage/build.log" 2>&1; then
  cp "$stage/build.log" build/tools/zsign-build.log
  echo 'Official zsign build failed; see build/tools/zsign-build.log.' >&2
  exit 1
fi
install -m755 "$stage/source/bin/zsign" "$stage/zsign"
cp "$stage/source/LICENSE" "$stage/zsign-LICENSE"
python3 - "$stage" "$commit" "$compiler" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
stage=Path(sys.argv[1])
record={'repository':'https://github.com/zhlynn/zsign','commit':sys.argv[2],'version':'1.1.2',
        'sha256':hashlib.sha256((stage/'zsign').read_bytes()).hexdigest(),
        'build':'Unmodified pinned official source; macOS Makefile with VERSION=1.1.2.',
        'compiler':subprocess.check_output([sys.argv[3],'--version'],text=True).splitlines()[0],
        'openssl':subprocess.check_output(['pkg-config','--modversion','openssl'],text=True).strip()}
(stage/'zsign-provenance.json').write_text(json.dumps(record,indent=2)+'\n')
PY
mv "$stage/zsign" build/tools/zsign
mv "$stage/zsign-provenance.json" build/tools/zsign-provenance.json
mv "$stage/zsign-LICENSE" build/tools/zsign-LICENSE
echo 'Built official zsign 1.1.2 from the pinned commit; recorded this build’s checksum in build/tools/zsign-provenance.json.'
