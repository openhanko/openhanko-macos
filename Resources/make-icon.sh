#!/bin/bash
# Regenerates OpenHanko.icns from icon.svg. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf OpenHanko.iconset && mkdir OpenHanko.iconset
for s in 16 32 128 256 512; do
  rsvg-convert -w $s      -h $s      icon.svg -o "OpenHanko.iconset/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) icon.svg -o "OpenHanko.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns OpenHanko.iconset -o OpenHanko.icns
rm -rf OpenHanko.iconset
echo "wrote $(du -h OpenHanko.icns | cut -f1) OpenHanko.icns"
