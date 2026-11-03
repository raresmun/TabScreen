#!/bin/bash
# Double-click to create TabScreen's app icon with ChatGPT image generation (through the Codex CLI),
# then rebuild TabScreen with it. Everything printed is also saved to icon.log.
cd "$(dirname "$0")"
DIR="$(pwd)"
exec > >(tee icon.log) 2>&1

echo "== Making the TabScreen icon ($(date)) =="
CODEX="$(command -v codex || true)"
if [ -z "$CODEX" ]; then
  for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex "$HOME/.homebrew/bin/codex" \
                   "$HOME/.npm-global/bin/codex" "$HOME/.bun/bin/codex" "$HOME/.local/bin/codex"; do
    if [ -x "$candidate" ]; then CODEX="$candidate"; break; fi
  done
fi
if [ -z "$CODEX" ]; then
  echo "Couldn't find the Codex CLI ('codex')."
  echo "Install it with:  npm install -g @openai/codex   and log in with:  codex login"
  exit 1
fi
echo "Using $CODEX ($("$CODEX" --version 2>/dev/null))"

GENERATED="${CODEX_HOME:-$HOME/.codex}/generated_images"
MARKER="$(mktemp)"
sleep 1

PROMPT='$imagegen Create the app icon artwork for "TabScreen", a macOS app that turns an Android tablet into an extra display for a MacBook.
Subject: a sleek laptop and a tablet standing side by side, with a soft glowing band of light flowing from the laptop screen onto the tablet screen, showing the desktop extending across both. The two screens show one calm abstract wallpaper that continues from the laptop onto the tablet.
Style: polished modern macOS app icon, soft 3D, glass and brushed aluminium, gentle studio lighting, rich gradient background from deep indigo to electric blue with a subtle violet glow.
Composition: square 1024x1024, full-bleed: the background fills the whole canvas edge to edge, with no rounded corners, no border or frame, and no shadow around the edges. Keep the devices centred with about 15 percent margin on every side, so it still looks good when the corners are rounded later.
No text, no letters, no numbers, no logos or brand marks.
Only generate the image; do not change any files. When it is saved, reply with the full path of the PNG.'

echo "-- Asking ChatGPT (via Codex) for the artwork – this takes about a minute"
"$CODEX" exec -C "$DIR" -s read-only --skip-git-repo-check "$PROMPT" || echo "(codex finished with an error)"

NEWEST=""
if [ -d "$GENERATED" ]; then
  while IFS= read -r -d '' file; do
    if [ -z "$NEWEST" ] || [ "$file" -nt "$NEWEST" ]; then NEWEST="$file"; fi
  done < <(find "$GENERATED" -type f -name '*.png' -newer "$MARKER" -print0 2>/dev/null)
fi
rm -f "$MARKER"
if [ -z "$NEWEST" ]; then
  echo ""
  echo "No new image showed up in $GENERATED."
  echo "Make sure Codex is up to date (npm install -g @openai/codex) and logged in (codex login), then try again."
  exit 1
fi
cp "$NEWEST" icon-source.png
echo "Artwork saved as icon-source.png (from $NEWEST)"

echo "-- Shaping it into a macOS icon"
mkdir -p build
xcrun swiftc -O Resources/MakeIcon.swift -o build/makeicon || exit 1
./build/makeicon icon-source.png AppIcon.png || exit 1

rm -rf build/AppIcon.iconset
mkdir -p build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns || exit 1
echo "Icon saved: Resources/AppIcon.icns"

echo "-- Rebuilding TabScreen with the new icon"
if pgrep -x TabScreen >/dev/null; then pkill -x TabScreen; sleep 1; fi
if bash ./build.sh; then
  open TabScreen.app
  open -a Preview AppIcon.png
  echo ""
  echo "Done! TabScreen restarted with its new icon (also open in Preview)."
  echo "macOS treats the rebuilt app as new, so allow Screen Recording for TabScreen again when it asks."
else
  echo "The rebuild failed – see build.log."
fi
