#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUNDLE_ID="com.justin.Kehai"
DERIVED_DATA="$ROOT/.build/DerivedData"
IDENTITY="Developer ID Application: Justin Henry Garcia (XDWKSAH7W3)"
RESET=1

if [[ "${1:-}" == "--no-reset" ]]; then
  RESET=0
elif [[ $# -gt 0 ]]; then
  print -u2 "Usage: $0 [--no-reset]"
  exit 64
fi

if (( RESET )); then
  "$ROOT/Scripts/reset-permissions.sh"
else
  /usr/bin/pkill -x Kehai 2>/dev/null || true
fi

cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
/bin/rm -rf "$DERIVED_DATA"
/usr/bin/xcodebuild \
  -project Kehai.xcodeproj \
  -scheme Kehai \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM=XDWKSAH7W3 \
  build

APP="$DERIVED_DATA/Build/Products/Debug/Kehai.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]]
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements "$ROOT/Kehai/Resources/Kehai.entitlements" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign -d --entitlements - "$APP"
/usr/bin/open "$APP"
print "Launched $APP"
