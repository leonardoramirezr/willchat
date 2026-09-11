#!/usr/bin/env bash
set -euo pipefail

# generate_icons.sh
# Generates an AppIcon.icns for macOS from a master SVG.
#
# Requirements:
#   brew install librsvg   # provides `rsvg-convert`
#
# Usage:
#   ./generate_icons.sh logo.svg [output_name]
#   ./generate_icons.sh logo.svg AppIcon
#
# Produces AppIcon.icns in the current directory (deletes the temporary
# .iconset folder when finished).

SVG="${1:?Usage: $0 file.svg [output_name]}"
NAME="${2:-AppIcon}"
ICONSET="${NAME}.iconset"

if [ ! -f "$SVG" ]; then
  echo "Error: file '$SVG' not found" >&2
  exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "Error: rsvg-convert is missing. Install it with: brew install librsvg" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# size_px:file_name (standard .iconset convention)
SIZES=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

echo "Generating ${#SIZES[@]} sizes from $SVG..."
for entry in "${SIZES[@]}"; do
  px="${entry%%:*}"
  file="${entry##*:}"
  rsvg-convert -w "$px" -h "$px" "$SVG" -o "${ICONSET}/${file}"
  echo "  -> ${file} (${px}x${px})"
done

iconutil -c icns "$ICONSET" -o "${NAME}.icns"
rm -rf "$ICONSET"

echo "Done: ${NAME}.icns"
