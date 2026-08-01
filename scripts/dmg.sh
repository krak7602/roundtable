#!/usr/bin/env bash
# Build the installer disk image: the window users actually see when they open
# the download. Roundtable.app on the left, a link to /Applications on the right,
# drag across to install.
#
# hdiutil alone can't do this. Window size, icon positions and the background
# image live in the volume's .DS_Store, and the only supported way to write one
# is to mount a read-write image and drive Finder through AppleScript — which is
# why this is a script rather than two lines in the workflow.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="Roundtable.app"
VOLUME="Roundtable"
DMG="Roundtable.dmg"
STAGE="dmg-staging"
RW="dmg-rw.dmg"

[[ -d "$APP" ]] || { echo "error: $APP not found — run scripts/bundle.sh first" >&2; exit 1; }

# Window geometry. The background is drawn at exactly these dimensions, so the
# icon positions below are in the same coordinate space as the image.
WIDTH=600
HEIGHT=400
ICON_Y=190
APP_X=150
LINK_X=450

echo "[dmg] staging"
hdiutil detach "/Volumes/$VOLUME" >/dev/null 2>&1 || true
rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# One TIFF holding both scales. Finder has no @2x convention for disk image
# backgrounds, so a multi-representation TIFF is the only way the text stays
# sharp on a Retina display instead of being upscaled from the 1x copy.
tiffutil -cathidpicheck \
  Resources/dmg-background.png \
  Resources/dmg-background@2x.png \
  -out "$STAGE/.background/background.tiff" >/dev/null

# Room for the .DS_Store Finder is about to write.
SIZE=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))

echo "[dmg] creating a writable image"
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
  -format UDRW -size "${SIZE}m" -ov "$RW" >/dev/null
hdiutil attach "$RW" -readwrite -noverify -noautoopen >/dev/null

# Finder automation can be refused outright on a machine where nothing has
# granted it — a CI runner, most likely. A plain image still installs correctly,
# so degrade to one rather than failing the release, but say so loudly: the
# difference is invisible in the artifact and would otherwise ship unnoticed.
echo "[dmg] arranging the window"
if ! osascript <<EOF >/dev/null
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, $((200 + WIDTH)), $((160 + HEIGHT))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP" of container window to {$APP_X, $ICON_Y}
    set position of item "Applications" of container window to {$LINK_X, $ICON_Y}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
then
  echo "::warning::Finder automation failed — shipping an unstyled disk image"
  STYLED=no
else
  STYLED=yes
fi

# Finder writes .DS_Store lazily; detaching too early loses the layout.
sync

# Finder can still be holding the volume when we ask for it back, which fails
# with "Resource busy" — a race, so it passes most of the time and then doesn't.
# Retry before resorting to -force, since a forced eject risks losing the
# .DS_Store we just went to the trouble of writing.
detached=no
for attempt in 1 2 3 4 5; do
  if hdiutil detach "/Volumes/$VOLUME" >/dev/null 2>&1; then detached=yes; break; fi
  sleep "$attempt"
done
if [[ "$detached" == "no" ]]; then
  echo "::warning::volume still busy after 15s — forcing the eject"
  hdiutil detach "/Volumes/$VOLUME" -force >/dev/null
fi

echo "[dmg] compressing"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

# Signing the image as well as the app inside it means the container can be
# verified before it is ever mounted, rather than only its contents afterwards.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "[sign] codesign $DMG"
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi

echo "[done] built $DMG ($(du -h "$DMG" | cut -f1)), styled=$STYLED"
