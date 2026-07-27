#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
exec "$ROOT/Scripts/reset-build-run.sh" --no-reset
