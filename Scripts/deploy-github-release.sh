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
WEBSITE_DIR="${WEBSITE_DIR:-$ROOT_DIR/../littlebobert.github.io}"
LANDING_PAGE="${LANDING_PAGE:-$WEBSITE_DIR/kehai.html}"
APPCAST_PATH="${APPCAST_PATH:-$WEBSITE_DIR/kehai-appcast.xml}"
APPCAST_PRODUCT_LINK="${APPCAST_PRODUCT_LINK:-https://littlebobert.github.io/kehai.html}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-kehai}"
PUBLIC_LANDING_URL="${PUBLIC_LANDING_URL:-https://littlebobert.github.io/kehai.html}"
PUBLIC_APPCAST_URL="${PUBLIC_APPCAST_URL:-https://littlebobert.github.io/kehai-appcast.xml}"
CURRENT_VERSION="$(ruby -e 'puts File.read(ARGV[0])[/MARKETING_VERSION: "([^"]+)"/, 1]' "$ROOT_DIR/project.yml")"
CURRENT_BUILD="$(ruby -e 'puts File.read(ARGV[0])[/CURRENT_PROJECT_VERSION: "([0-9]+)"/, 1]' "$ROOT_DIR/project.yml")"
VERSION_ARG=""
NOTES_FILE_ARG=""
DRY_RUN=false
NOTES=()

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/deploy-github-release.sh [version] --notes "Change" [--notes "Another change"]
  ./Scripts/deploy-github-release.sh [version] --notes-file PATH
  ./Scripts/deploy-github-release.sh --dry-run --notes "Change"

Without a version, bumps the patch version and increments the numeric build.
With an explicit version, uses that version and still increments the build.

The script validates the repositories, updates versions and release notes,
compiles tests and creates a notarized build, commits/pushes Kehai, creates the GitHub release,
generates and deploys the Sparkle appcast and landing-page changelog, then
redownloads and verifies the public artifact.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)
      shift
      [[ $# -gt 0 ]] || { echo "error: --notes requires text" >&2; exit 1; }
      NOTES+=("$1")
      ;;
    --notes-file)
      shift
      [[ $# -gt 0 ]] || { echo "error: --notes-file requires a path" >&2; exit 1; }
      NOTES_FILE_ARG="$1"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      [[ -z "$VERSION_ARG" ]] || { echo "error: only one version may be supplied" >&2; exit 1; }
      VERSION_ARG="${1#v}"
      ;;
  esac
  shift
done

for command in curl gh git python3 ruby xcodebuild xcodegen xmllint; do
  command -v "$command" >/dev/null || { echo "error: missing required command: $command" >&2; exit 1; }
done
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid current version: $CURRENT_VERSION" >&2; exit 1; }
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || { echo "error: invalid current build: $CURRENT_BUILD" >&2; exit 1; }

if [[ -n "$VERSION_ARG" ]]; then
  VERSION="$VERSION_ARG"
else
  IFS='.' read -r major minor patch <<<"$CURRENT_VERSION"
  VERSION="$major.$minor.$((10#$patch + 1))"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid release version: $VERSION" >&2; exit 1; }
BUILD="$((10#$CURRENT_BUILD + 1))"
TAG="${RELEASE_TAG:-$VERSION}"
RELEASE_DIR="$ROOT_DIR/.build/releases"
RELEASE_ZIP="$RELEASE_DIR/Kehai-$VERSION-mac.zip"
NOTES_FILE="$RELEASE_DIR/release-notes-$VERSION.md"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/Kehai-$VERSION-mac.zip"
KEHAI_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
WEBSITE_BRANCH="$(git -C "$WEBSITE_DIR" branch --show-current)"

[[ -n "$KEHAI_BRANCH" && -n "$WEBSITE_BRANCH" ]] || { echo "error: detached HEAD is not supported" >&2; exit 1; }
[[ -f "$LANDING_PAGE" ]] || { echo "error: landing page not found: $LANDING_PAGE" >&2; exit 1; }
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || { echo "error: Kehai working tree must be clean before deployment" >&2; exit 1; }
[[ -z "$(git -C "$WEBSITE_DIR" status --porcelain)" ]] || { echo "error: website working tree must be clean before deployment" >&2; exit 1; }
git -C "$ROOT_DIR" fetch origin "$KEHAI_BRANCH"
git -C "$WEBSITE_DIR" fetch origin "$WEBSITE_BRANCH"
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$(git -C "$ROOT_DIR" rev-parse "origin/$KEHAI_BRANCH")" ]] || { echo "error: Kehai branch is not synchronized with origin" >&2; exit 1; }
[[ "$(git -C "$WEBSITE_DIR" rev-parse HEAD)" == "$(git -C "$WEBSITE_DIR" rev-parse "origin/$WEBSITE_BRANCH")" ]] || { echo "error: website branch is not synchronized with origin" >&2; exit 1; }
gh auth status >/dev/null
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "error: GitHub release $TAG already exists" >&2; exit 1; }

mkdir -p "$RELEASE_DIR"
if [[ -n "$NOTES_FILE_ARG" ]]; then
  [[ -f "$NOTES_FILE_ARG" ]] || { echo "error: notes file not found: $NOTES_FILE_ARG" >&2; exit 1; }
  cp "$NOTES_FILE_ARG" "$NOTES_FILE"
elif [[ ${#NOTES[@]} -gt 0 ]]; then
  {
    for note in "${NOTES[@]}"; do echo "- $note"; done
  } > "$NOTES_FILE"
else
  echo "error: provide at least one --notes value or --notes-file" >&2
  exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run passed: $CURRENT_VERSION ($CURRENT_BUILD) -> $VERSION ($BUILD)"
  echo "GitHub release: $REPO tag $TAG"
  echo "Landing page: $LANDING_PAGE"
  echo "Appcast: $APPCAST_PATH"
  exit 0
fi

"$ROOT_DIR/Scripts/bump-version.sh" "$VERSION" "$BUILD"

python3 - "$LANDING_PAGE" "$VERSION" "$DOWNLOAD_URL" "$NOTES_FILE" <<'PY'
from pathlib import Path
import html, re, sys
page_path = Path(sys.argv[1])
version = sys.argv[2]
download_url = sys.argv[3]
notes_path = Path(sys.argv[4])
page = page_path.read_text()
notes = []
for line in notes_path.read_text().splitlines():
    line = line.strip()
    if line.startswith("- "):
        notes.append(line[2:].strip())
if not notes:
    raise SystemExit("error: release notes contain no bullet items")
page, download_count = re.subn(r'href="https://github\.com/littlebobert/kehai/releases/download/[^/]+/Kehai-[^"]+-mac\.zip"', f'href="{download_url}"', page, count=1)
page, version_count = re.subn(r'<span class="kehai-version">\(version [^)]+\)</span>', f'<span class="kehai-version">(version {version})</span>', page, count=1)
if download_count != 1 or version_count != 1:
    raise SystemExit("error: landing-page download/version markers were not found exactly once")
items = "\n".join(f"          <li>{html.escape(note)}</li>" for note in notes)
entry = f'''        <h2>{html.escape(version)}</h2>\n        <ul>\n{items}\n        </ul>\n'''
marker = '        <summary>Changelog</summary>\n'
if marker not in page:
    raise SystemExit("error: changelog marker not found")
page = page.replace(marker, marker + entry, 1)
page_path.write_text(page)
PY

xcodebuild -project "$ROOT_DIR/Kehai.xcodeproj" -scheme Kehai -configuration Debug \
  -derivedDataPath "$ROOT_DIR/.build/DeployTests" -destination 'platform=macOS,arch=arm64' build-for-testing
if [[ "${RUN_HOSTED_TESTS:-0}" == "1" ]]; then
  python3 - "$ROOT_DIR" <<'PY'
import os, signal, subprocess, sys
root = sys.argv[1]
command = [
    "xcodebuild", "-project", f"{root}/Kehai.xcodeproj", "-scheme", "Kehai",
    "-configuration", "Debug", "-derivedDataPath", f"{root}/.build/DeployTests",
    "-destination", "platform=macOS,arch=arm64", "test-without-building",
]
process = subprocess.Popen(command, start_new_session=True)
try:
    result = process.wait(timeout=120)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
    raise SystemExit("error: hosted tests exceeded the two-minute safety timeout")
if result != 0:
    raise SystemExit(result)
PY
fi
"$ROOT_DIR/Scripts/build-release.sh"
"$ROOT_DIR/Scripts/notarize-release.sh"

APP="$ROOT_DIR/.build/ReleaseDerivedData/Build/Products/Release/Kehai.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || { echo "error: built version mismatch" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] || { echo "error: built build-number mismatch" >&2; exit 1; }
[[ -f "$RELEASE_ZIP" && -f "$RELEASE_ZIP.sha256" ]] || { echo "error: release artifact missing" >&2; exit 1; }

SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$ROOT_DIR/.build/ReleaseDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
APPCAST_WORK="$ROOT_DIR/.build/appcast"
rm -rf "$APPCAST_WORK"
mkdir -p "$APPCAST_WORK"
cp "$RELEASE_ZIP" "$APPCAST_WORK/"
cp "$NOTES_FILE" "$APPCAST_WORK/Kehai-$VERSION-mac.md"
[[ -f "$APPCAST_PATH" ]] && cp "$APPCAST_PATH" "$APPCAST_WORK/appcast.xml"
"$SPARKLE_GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes \
  --link "$APPCAST_PRODUCT_LINK" \
  --maximum-deltas 0 \
  --versions "$BUILD" \
  -o "$APPCAST_WORK/appcast.xml" \
  "$APPCAST_WORK"
cp "$APPCAST_WORK/appcast.xml" "$APPCAST_PATH"

rm -f "$NOTES_FILE"
git -C "$ROOT_DIR" add -A
git -C "$ROOT_DIR" commit -m "Release Kehai $VERSION"
git -C "$ROOT_DIR" push origin "$KEHAI_BRANCH"
gh release create "$TAG" "$RELEASE_ZIP" "$RELEASE_ZIP.sha256" \
  --repo "$REPO" --target "$KEHAI_BRANCH" --title "Kehai $VERSION" --notes-file "$APPCAST_WORK/Kehai-$VERSION-mac.md"

LANDING_RELATIVE="${LANDING_PAGE#"$WEBSITE_DIR"/}"
APPCAST_RELATIVE="${APPCAST_PATH#"$WEBSITE_DIR"/}"
git -C "$WEBSITE_DIR" add "$LANDING_RELATIVE" "$APPCAST_RELATIVE"
git -C "$WEBSITE_DIR" commit -m "Publish Kehai $VERSION"
git -C "$WEBSITE_DIR" push origin "$WEBSITE_BRANCH"

VERIFY_DIR="$(mktemp -d /tmp/kehai-release.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
curl -fL "$DOWNLOAD_URL" -o "$VERIFY_DIR/Kehai-$VERSION-mac.zip"
EXPECTED="$(cut -d' ' -f1 "$RELEASE_ZIP.sha256")"
ACTUAL="$(shasum -a 256 "$VERIFY_DIR/Kehai-$VERSION-mac.zip" | cut -d' ' -f1)"
[[ "$EXPECTED" == "$ACTUAL" ]] || { echo "error: public checksum mismatch" >&2; exit 1; }
/usr/bin/unzip -q "$VERIFY_DIR/Kehai-$VERSION-mac.zip" -d "$VERIFY_DIR/extracted"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/extracted/Kehai.app"
xcrun stapler validate "$VERIFY_DIR/extracted/Kehai.app"
spctl --assess --type execute --verbose=4 "$VERIFY_DIR/extracted/Kehai.app"

for attempt in {1..24}; do
  if curl -fL "$PUBLIC_APPCAST_URL" -o "$VERIFY_DIR/appcast.xml" 2>/dev/null && \
     curl -fL "$PUBLIC_LANDING_URL" -o "$VERIFY_DIR/landing.html" 2>/dev/null && \
     xmllint --noout "$VERIFY_DIR/appcast.xml" && \
     grep -Fq "<sparkle:version>$BUILD</sparkle:version>" "$VERIFY_DIR/appcast.xml" && \
     grep -Fq "$DOWNLOAD_URL" "$VERIFY_DIR/landing.html"; then
    echo "Published and verified Kehai $VERSION ($BUILD)"
    echo "https://github.com/$REPO/releases/tag/$TAG"
    exit 0
  fi
  sleep 10
done

echo "error: release is published, but the public website/feed did not verify within four minutes" >&2
exit 1
