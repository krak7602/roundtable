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
cp -R Resources/HarnessIcons "$CONTENTS/Resources/HarnessIcons"

# Signed for real when an identity is available, ad-hoc otherwise. Only a
# Developer ID signature can be notarized, and notarization in turn requires the
# hardened runtime — which is why the entitlements come along: it blocks the
# Apple Events we use to drive terminals unless we ask for them.
#
# --deep is deliberately absent. Apple deprecated it, and this bundle has no
# nested code for it to reach anyway: one executable and some resources.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "[sign] codesign as $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Roundtable.entitlements \
    --sign "$CODESIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=1 "$APP"
else
  echo "[sign] ad-hoc codesign (unsigned build — Gatekeeper will block it)"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "[done] built $APP"
echo "  run:  open $APP    (the orb appears against a screen edge)"
echo "  log:  log stream --predicate 'process == \"Roundtable\"' --level debug"
