#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.justin.Kehai"

/usr/bin/pkill -x Kehai 2>/dev/null || true
/usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID"
/usr/bin/tccutil reset Accessibility "$BUNDLE_ID"
/usr/bin/tccutil reset AppleEvents "$BUNDLE_ID"
/usr/bin/defaults delete "$BUNDLE_ID" permissionAttempted.screenCapture 2>/dev/null || true
/usr/bin/defaults delete "$BUNDLE_ID" permissionAttempted.accessibility 2>/dev/null || true

print "Reset Screen Recording, Accessibility, and Safari Automation permissions for $BUNDLE_ID"
