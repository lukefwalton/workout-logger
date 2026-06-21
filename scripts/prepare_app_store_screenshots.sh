#!/usr/bin/env bash
# Flatten PNG screenshots (no alpha) for App Store Connect upload.
# Usage:  ./scripts/prepare_app_store_screenshots.sh ~/Downloads/*.png
# Output: build/app-store-screenshots/

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/app-store-screenshots"
mkdir -p "$OUT"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 path/to/screenshot.png [more.png ...]"
  echo "Tip: AirDrop full-size iPhone screenshots from Photos — not chat attachments."
  exit 1
fi

i=0
for src in "$@"; do
  [[ -f "$src" ]] || { echo "Skip (not a file): $src"; continue; }
  i=$((i + 1))
  dest="$OUT/$(printf '%02d' "$i")-$(basename "${src%.*}").png"
  tmp="${dest%.png}.jpg"
  sips -s format jpeg -s formatOptions 100 "$src" --out "$tmp" >/dev/null
  sips -s format png "$tmp" --out "$dest" >/dev/null
  rm -f "$tmp"
  w=$(sips -g pixelWidth "$dest" 2>/dev/null | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$dest" 2>/dev/null | awk '/pixelHeight/{print $2}')
  alpha=$(sips -g hasAlpha "$dest" 2>/dev/null | awk '/hasAlpha/{print $2}')
  echo "$dest  ${w}x${h}  alpha=$alpha"
  if [[ "$w" -lt 1200 ]]; then
    echo "  ⚠️  Too small for 6.5\" App Store (need ~1284×2778). Use iPhone screenshot or simulator."
  fi
done

echo ""
echo "Done → $OUT/"
open "$OUT"
