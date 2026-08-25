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

REPO="${GITHUB_REPO:-littlebobert/kehai}"
LANDING_PAGE="${LANDING_PAGE:-$ROOT_DIR/../littlebobert.github.io/kehai.html}"
APPCAST_PATH="${APPCAST_PATH:-$(dirname "$LANDING_PAGE")/kehai-appcast.xml}"
APPCAST_PRODUCT_LINK="${APPCAST_PRODUCT_LINK:-https://kehai.jp/}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-kehai}"
TOOLS_DIR="$ROOT_DIR/.build/ReleaseDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$TOOLS_DIR/generate_appcast}"
VERSION="$(ruby -e 'puts File.read(ARGV[0])[/MARKETING_VERSION: "([^"]+)"/, 1]' "$ROOT_DIR/project.yml")"
BUILD="$(ruby -e 'puts File.read(ARGV[0])[/CURRENT_PROJECT_VERSION: "([0-9]+)"/, 1]' "$ROOT_DIR/project.yml")"
TAG="${RELEASE_TAG:-$VERSION}"
RELEASE_ZIP="$ROOT_DIR/.build/releases/Kehai-$VERSION-mac.zip"
NOTES_FILE="${NOTES_FILE:-$ROOT_DIR/.build/releases/release-notes-$VERSION.md}"
APPCAST_WORK="$ROOT_DIR/.build/appcast"

for command in gh git xcrun; do command -v "$command" >/dev/null || { echo "error: $command is required" >&2; exit 1; }; done
[[ -x "$GENERATE_APPCAST" ]] || { echo "error: generate_appcast not found: $GENERATE_APPCAST" >&2; exit 1; }
[[ -f "$LANDING_PAGE" ]] || { echo "error: landing page not found: $LANDING_PAGE" >&2; exit 1; }
[[ -f "$NOTES_FILE" ]] || { echo "error: release notes not found: $NOTES_FILE" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "error: build must be numeric" >&2; exit 1; }
gh auth status >/dev/null
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "error: release $TAG already exists" >&2; exit 1; }

[[ -f "$RELEASE_ZIP" ]] || "$ROOT_DIR/Scripts/notarize-release.sh" >/dev/null

mkdir -p "$APPCAST_WORK"
rm -f "$APPCAST_WORK"/*
cp "$RELEASE_ZIP" "$APPCAST_WORK/"
cp "$NOTES_FILE" "$APPCAST_WORK/Kehai-$VERSION-mac.md"
[[ -f "$APPCAST_PATH" ]] && cp "$APPCAST_PATH" "$APPCAST_WORK/appcast.xml"

"$GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes \
  --link "$APPCAST_PRODUCT_LINK" \
  --maximum-deltas 0 \
  --versions "$BUILD" \
  -o "$APPCAST_WORK/appcast.xml" \
  "$APPCAST_WORK"

cp "$APPCAST_WORK/appcast.xml" "$APPCAST_PATH"
gh release create "$TAG" "$RELEASE_ZIP" "$RELEASE_ZIP.sha256" \
  --repo "$REPO" \
  --title "Kehai $VERSION" \
  --notes-file "$NOTES_FILE"

echo "Published GitHub release $TAG and generated $APPCAST_PATH"
echo "Commit and push the website repository after verifying the public artifact."
