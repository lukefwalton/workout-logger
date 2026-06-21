#!/usr/bin/env bash
# Seed bench progress in the simulator and capture a 6.5" Progress screenshot.
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/generate.sh

# iPhone 14 Plus → 1284×2778 (App Store 6.5" size)
SIM_ID="${SIM_ID:-6663E953-C97C-43F3-9E12-140B7AFEAC81}"
BUNDLE="com.lukewalton.workoutchatlog"
OUT="build/app-store-screenshots/02-progress.png"
mkdir -p build/app-store-screenshots

echo "Building for simulator..."
xcodebuild build \
  -scheme WorkoutChatLog \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO >/dev/null

APP="build/DerivedData/Build/Products/Debug-iphonesimulator/WorkoutChatLog.app"
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$SIM_ID"
sleep 2

xcrun simctl uninstall "$SIM_ID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP"

# Skip onboarding on a fresh install.
xcrun simctl spawn "$SIM_ID" defaults write "$BUNDLE" hasCompletedWorkoutOnboarding -bool true

xcrun simctl launch "$SIM_ID" "$BUNDLE" -- -SeedDemoProgress -OpenProgress
sleep 5

echo "Capturing Progress tab..."
xcrun simctl io "$SIM_ID" screenshot /tmp/wcl-progress-raw.png

# Flatten alpha + exact App Store dimensions.
sips -s format jpeg -s formatOptions 100 /tmp/wcl-progress-raw.png --out /tmp/wcl-progress.jpg >/dev/null
sips -s format png /tmp/wcl-progress.jpg --out "$OUT" >/dev/null
rm -f /tmp/wcl-progress.jpg
sips -z 2778 1284 "$OUT" --out "$OUT" >/dev/null

W=$(sips -g pixelWidth "$OUT" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/{print $2}')
A=$(sips -g hasAlpha "$OUT" | awk '/hasAlpha/{print $2}')
echo "Saved $OUT (${W}x${H}, alpha=$A)"
open "$(dirname "$OUT")"
