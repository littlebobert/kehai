#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/.build/ReleaseDerivedData}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Justin Henry Garcia (XDWKSAH7W3)}"
TEAM_ID="${DEVELOPMENT_TEAM:-XDWKSAH7W3}"
APP="$DERIVED_DATA/Build/Products/Release/Kehai.app"

cd "$ROOT_DIR"
command -v xcodegen >/dev/null || { echo "error: xcodegen is required" >&2; exit 1; }
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -Fq "$IDENTITY" <<<"$IDENTITIES" || {
  echo "error: expected signing identity not found: $IDENTITY" >&2
  exit 1
}

xcodegen generate
xcodebuild \
  -project Kehai.xcodeproj \
  -scheme Kehai \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build

[[ -d "$APP" ]] || { echo "error: release app not found: $APP" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "com.justin.Kehai" ]] || {
  echo "error: unexpected bundle identifier" >&2; exit 1
}
[[ "$(lipo -archs "$APP/Contents/MacOS/Kehai")" == "arm64" ]] || {
  echo "error: release executable must be arm64-only" >&2; exit 1
}

codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp \
  "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign "$IDENTITY" --entitlements "$ROOT_DIR/Kehai/Resources/Kehai.entitlements" \
  --options runtime --timestamp "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -Fq "get-task-allow"; then
  echo "error: release app contains get-task-allow" >&2
  exit 1
fi
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$SIGNATURE_DETAILS" || {
  echo "error: release app was not signed by team $TEAM_ID" >&2
  exit 1
}

printf '%s\n' "$APP"
