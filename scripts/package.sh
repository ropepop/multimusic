#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app=youtube
base=org.multimusic.app
usage() { echo 'Usage: scripts/package.sh [--app youtube|spotify] [--bundle-base your.unique.Multimusic]'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app|--bundle-base)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in --app) app=$2 ;; --bundle-base) base=$2 ;; esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
python3 - "$base" <<'PY'
import sys
sys.path.insert(0, 'scripts')
from signing_entitlements import concrete_identifier
if not concrete_identifier(sys.argv[1]):
    raise SystemExit('Choose a concrete reverse-DNS bundle base.')
PY
case "$app" in
  youtube) product=Multimusic; adapter=YouTubeMusic; derived=build/DerivedData ;;
  spotify) product=MultimusicSpotify; adapter=Spotify; derived=build/DerivedData-Spotify ;;
  *) echo 'Choose --app youtube or --app spotify.' >&2; exit 2 ;;
esac
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo 'Select a full Xcode installation with xcode-select or DEVELOPER_DIR, including its iOS SDK.' >&2
  exit 2
fi
xcodebuild -quiet -project Multimusic.xcodeproj -scheme "$product" \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  "MULTIMUSIC_BUNDLE_BASE=$base" MULTIMUSIC_DIAGNOSTICS_ORIGIN= MULTIMUSIC_DIAGNOSTICS_DATABASE= build
stage=$(mktemp -d "${TMPDIR:-/tmp}/multimusic-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/Payload" build
ditto --norsrc --noextattr "$derived/Build/Products/Release-iphoneos/$product.app" "$stage/Payload/$product.app"
test -x "$stage/Payload/$product.app/$product"
test -s "$stage/Payload/$product.app/$adapter.js"
plutil -lint "$stage/Payload/$product.app/Info.plist"
cmp "Multimusic/Resources/$adapter.js" "$stage/Payload/$product.app/$adapter.js"
(
  cd "$stage"
  export TZ=UTC
  find Payload -exec touch -h -t 198001010000 {} +
  find Payload -print | LC_ALL=C sort | zip -X -q "$product-unsigned.ipa" -@
)
python3 - "$stage/$product-unsigned.ipa" "$app" "$base" <<'PY'
import sys
sys.path.insert(0, 'scripts')
from signing_entitlements import inspect_unsigned_archive
info, _ = inspect_unsigned_archive(sys.argv[1], sys.argv[2])
if info['MultimusicPrimaryBundleIdentifier'] != sys.argv[3]:
    raise SystemExit('Packaged bundle base differs from the requested identity.')
PY
mv "$stage/$product-unsigned.ipa" "build/$product-unsigned.ipa"
echo "Created build/$product-unsigned.ipa with remote diagnostics disabled."
