#!/bin/bash
# Double-click this file in Finder to make dist/TabScreen.dmg, the disk image people download from the Releases page,
# with the tablet app copied next to it as dist/TabScreen.apk. Everything printed is also saved to dmg.log.
#
# The app inside is signed with this Mac's TabScreen certificate (see build.sh), so people who update from one of
# these disk images to the next keep their Screen Recording permission. It isn't notarized by Apple (that needs a
# paid Apple developer membership), so the first time people open it, macOS asks them to allow it in
# System Settings → Privacy & Security.
cd "$(dirname "$0")"
exec > >(tee dmg.log) 2>&1

APP="build/release/TabScreen.app"   # built apart from ./TabScreen.app, so a running TabScreen isn't disturbed
STAGE="build/dmg"
DMG="dist/TabScreen.dmg"

rm -rf build/release "$STAGE"
if ! TABSCREEN_APP="$APP" bash ./build.sh; then
  echo ""
  echo "The build failed. Tell Claude – the details are in dmg.log in this folder."
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "== Making the disk image for TabScreen $VERSION =="
mkdir -p "$STAGE" dist
ln -s /Applications "$STAGE/Applications"   # so people can drag the app straight into Applications
rm -f "$DMG"
if ! ditto "$APP" "$STAGE/TabScreen.app" \
  || ! hdiutil create -volname "TabScreen" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"; then
  echo ""
  echo "Making the disk image failed. Tell Claude – the details are in dmg.log in this folder."
  exit 1
fi
cp Android/TabScreen.apk dist/TabScreen.apk

echo "-- Checking the disk image"
MOUNT="$(mktemp -d)"
if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null; then
  if codesign --verify --deep --strict "$MOUNT/TabScreen.app"; then
    echo "   The app inside is complete and its signature is intact"
  else
    echo "   WARNING: the app's signature doesn't check out"
  fi
  codesign -dvv "$MOUNT/TabScreen.app" 2>&1 | grep -E '^(Identifier|Authority|Signature)=' | sed 's/^/   /'
  hdiutil detach "$MOUNT" >/dev/null || hdiutil detach -force "$MOUNT" >/dev/null
else
  echo "   WARNING: couldn't open the disk image to check it"
fi
rmdir "$MOUNT" 2>/dev/null

echo ""
du -h "$DMG" dist/TabScreen.apk
shasum -a 256 "$DMG" dist/TabScreen.apk
echo "== Done: TabScreen $VERSION in $DMG, and the tablet app in dist/TabScreen.apk =="
echo "You can close this window."
open -R "$DMG"
