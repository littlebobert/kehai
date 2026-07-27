#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/.build/DerivedData/Build/Products/Debug/Kehai.app"

if [[ ! -d "$APP" ]]; then
  print -u2 "Kehai has not been built at $APP"
  print -u2 "Build it first with ./Scripts/build-run.sh"
  exit 66
fi

/usr/bin/open "$APP"
print "Opened $APP"
