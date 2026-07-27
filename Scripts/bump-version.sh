#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/project.yml"
NEW_VERSION="${1#v}"
NEW_BUILD="${2:-}"

[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "usage: ./Scripts/bump-version.sh <semantic-version> [numeric-build]" >&2
  exit 1
}
CURRENT_BUILD="$(ruby -e 'puts File.read(ARGV[0])[/CURRENT_PROJECT_VERSION: "([0-9]+)"/, 1]' "$PROJECT")"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || { echo "error: current build is not numeric" >&2; exit 1; }
NEW_BUILD="${NEW_BUILD:-$((10#$CURRENT_BUILD + 1))}"
[[ "$NEW_BUILD" =~ ^[0-9]+$ ]] || { echo "error: build must be numeric" >&2; exit 1; }
(( 10#$NEW_BUILD > 10#$CURRENT_BUILD )) || { echo "error: build must increase beyond $CURRENT_BUILD" >&2; exit 1; }

python3 - "$PROJECT" "$NEW_VERSION" "$NEW_BUILD" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r'MARKETING_VERSION: "[^"]+"', f'MARKETING_VERSION: "{sys.argv[2]}"', text, count=1)
text = re.sub(r'CURRENT_PROJECT_VERSION: "[^"]+"', f'CURRENT_PROJECT_VERSION: "{sys.argv[3]}"', text, count=1)
path.write_text(text)
PY
xcodegen generate --spec "$PROJECT"
echo "Kehai version is now $NEW_VERSION ($NEW_BUILD)"
