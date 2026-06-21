#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

DEST='platform=iOS Simulator,id=DBA84C5A-C1EF-4BF1-8871-A9AF93BE08B0'
if ! xcrun simctl list devices available | grep -q "DBA84C5A-C1EF-4BF1-8871-A9AF93BE08B0"; then
  UDID=$(xcrun simctl list devices available --json \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['devices']; ids=[d['udid'] for ds in r.values() for d in ds if d['name'].startswith('iPhone') and d.get('isAvailable', True)]; print(ids[0] if ids else '')")
  if [ -z "$UDID" ]; then
    echo "No iPhone simulator found" >&2
    exit 1
  fi
  DEST="platform=iOS Simulator,id=$UDID"
fi

echo "Building Debug for simulator..."
xcodebuild build \
  -scheme WorkoutChatLog \
  -destination "$DEST" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO

APP=$(xcodebuild -showBuildSettings -scheme WorkoutChatLog -destination "$DEST" -configuration Debug 2>/dev/null \
  | awk -F' = ' '/TARGET_BUILD_DIR/ {dir=$2} /FULL_PRODUCT_NAME/ {name=$2} END {print dir"/"name}')

SIM_ID="${DEST#*id=}"
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl uninstall booted com.lukewalton.workoutchatlog 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.lukewalton.workoutchatlog
open -a Simulator

echo "Launched on simulator."
