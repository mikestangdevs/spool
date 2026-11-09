#!/bin/bash
# Builds a release binary and wraps it in build/Spool.app.
#
# Signing: by default the build is signed with a local self-signed identity, created on
# first run by scripts/setup-signing.sh, so macOS keeps the Accessibility permission across
# rebuilds. To sign with your own identity instead:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" scripts/bundle.sh
# To skip signing identities altogether (permission is lost on every rebuild):
#   SIGN_ID=- scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/Spool.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Spool" "$BIN/spoolctl" "$APP/Contents/MacOS/"
cp scripts/Spool.icns "$APP/Contents/Resources/Spool.icns"
cp scripts/Info.plist "$APP/Contents/Info.plist"

if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --sign "$SIGN_ID" "$APP"
elif scripts/setup-signing.sh; then
    codesign --force --sign "Spool Local Signing" \
        --keychain "$HOME/Library/Keychains/spool-signing.keychain-db" "$APP"
else
    echo "warning: could not set up local signing; falling back to ad-hoc." >&2
    echo "         macOS will ask for Accessibility again after each rebuild." >&2
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
