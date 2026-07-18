#!/usr/bin/env bash
# Build Roundtable and assemble it into a proper .app bundle so the menu-bar UI
# and UserNotifications work (both require a bundle identifier). Ad-hoc signs it
# so macOS lets it register for notifications and activate other apps.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

echo "[build] swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Roundtable"
APP="Roundtable.app"
CONTENTS="$APP/Contents"

echo "[bundle] assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Roundtable"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

echo "[sign] ad-hoc codesign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "[done] built $APP"
echo "  run:  open $APP    (look for the grid icon in the menu bar)"
echo "  log:  log stream --predicate 'process == \"Roundtable\"' --level debug"
