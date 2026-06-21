#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/generate.sh

ARCHIVE="build/WorkoutChatLog.xcarchive"
mkdir -p build

echo "Archiving for App Store / TestFlight..."
xcodebuild archive \
  -scheme WorkoutChatLog \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

echo ""
echo "Archive ready: $ARCHIVE"
echo "Upload via Xcode Organizer (Product → Archive) or:"
echo "  xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath build/export -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates"
