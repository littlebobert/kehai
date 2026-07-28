#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.justin.Kehai"

/usr/bin/pkill -x Kehai 2>/dev/null || true
/usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID"
/usr/bin/tccutil reset Accessibility "$BUNDLE_ID"
/usr/bin/tccutil reset AppleEvents "$BUNDLE_ID"

# App preferences live in UserDefaults; the OpenAI API key lives separately in Keychain.
/usr/bin/defaults delete "$BUNDLE_ID" 2>/dev/null || true

print "Reset Kehai permissions and preferences for $BUNDLE_ID"
print "Kept the OpenAI API key stored in Keychain"
