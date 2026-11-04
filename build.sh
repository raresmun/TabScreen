#!/bin/bash
# Builds TabScreen.app in this folder. Everything printed is also saved to build.log.
set -eo pipefail
cd "$(dirname "$0")"
exec > >(tee build.log) 2>&1

echo "== Building TabScreen ($(date)) =="
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's command line developer tools are missing."
  echo "Run this in Terminal, let it finish, then build again:"
  echo "    xcode-select --install"
  exit 1
fi
sw_vers || true
xcrun swiftc --version || true

APP="TabScreen.app"
REBUILD=0
if [ -f "$APP/Contents/MacOS/TabScreen" ]; then REBUILD=1; fi

mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "-- Compiling the virtual display bridge"
xcrun clang -fobjc-arc -fmodules -arch arm64 -mmacosx-version-min=13.0 \
  -c Sources/TSVirtualDisplay.m -o build/TSVirtualDisplay.o

echo "-- Compiling the app"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -import-objc-header Sources/TSVirtualDisplay.h \
  Sources/*.swift build/TSVirtualDisplay.o \
  -o "$APP/Contents/MacOS/TabScreen"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/viewer.html "$APP/Contents/Resources/viewer.html"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - "$APP"

touch "$APP"   # nudges Finder to refresh the icon
if [ "$REBUILD" = 1 ]; then
  # A rebuilt app counts as a new app for macOS privacy settings: clear the old Screen Recording entry
  # so macOS asks again instead of showing a switch that looks on but no longer works.
  tccutil reset ScreenCapture local.tabscreen >/dev/null 2>&1 || true
fi
echo "== Build succeeded: $APP =="
