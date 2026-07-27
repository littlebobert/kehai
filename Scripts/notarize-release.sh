#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-$ROOT_DIR/.env.release}"
if [[ -f "$RELEASE_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$RELEASE_ENV_FILE"
  set +a
fi

DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/.build/ReleaseDerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/Kehai.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-sasu-notary}"
VERSION="${MARKETING_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)}"
OUTPUT_DIR="$ROOT_DIR/.build/releases"
NOTARY_ZIP="$OUTPUT_DIR/Kehai-notary.zip"
RELEASE_ZIP="$OUTPUT_DIR/Kehai-$VERSION-mac.zip"

[[ -d "$APP" ]] || "$ROOT_DIR/Scripts/build-release.sh" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
RELEASE_ZIP="$OUTPUT_DIR/Kehai-$VERSION-mac.zip"
mkdir -p "$OUTPUT_DIR"
rm -f "$NOTARY_ZIP" "$RELEASE_ZIP"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
/usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"

/usr/bin/ditto --noextattr --norsrc -c -k --keepParent "$APP" "$RELEASE_ZIP"
VERIFY_DIR="$(mktemp -d "$OUTPUT_DIR/verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
/usr/bin/unzip -q "$RELEASE_ZIP" -d "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/Kehai.app"
xcrun stapler validate "$VERIFY_DIR/Kehai.app"
spctl --assess --type execute --verbose=4 "$VERIFY_DIR/Kehai.app"
shasum -a 256 "$RELEASE_ZIP" > "$RELEASE_ZIP.sha256"

printf '%s\n' "$RELEASE_ZIP"
