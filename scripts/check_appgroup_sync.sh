#!/usr/bin/env bash
#
# Keeps the App Group identifier in sync between the two places that declare it
# and can't see each other: project.yml's com.apple.security.application-groups
# entitlement (the build side, consumed by XcodeGen) and AppGroup.identifier in
# Swift (the runtime side). A mismatch can't be caught at compile time and would
# split the app and the Home Screen widget across two different databases, so we
# catch the drift here instead.
#
# Every target that shares the database (app + widget, PR 12) must use the *same*
# group, so we collect every identifier declared under any application-groups block
# and require one consistent value that matches Swift. `AppGroup` lives in the Shared
# module (SharedDatabase.swift) so both the app and the widget can read it without
# linking the WorkoutStore write path.
#
# Exits non-zero if they disagree or either side is missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$ROOT/project.yml"
APP_DB="$ROOT/WorkoutChatLog/Shared/SharedDatabase.swift"

# All `- group.…` list items under an `application-groups:` block, block-scoped
# (so a `group.` token elsewhere in the file can't be mistaken for one), sorted
# unique.
YAML_IDS=()
while IFS= read -r id; do
  YAML_IDS+=("$id")
done < <(awk '
  match($0, /^[ ]*/) { indent = RLENGTH }
  /application-groups:[[:space:]]*$/ { in_block = 1; key_indent = indent; next }
  in_block && $0 ~ /^[[:space:]]*-[[:space:]]*group\./ {
    v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); gsub(/[[:space:]"]/, "", v); print v; next
  }
  in_block && $0 ~ /[^[:space:]]/ && indent <= key_indent { in_block = 0 }
' "$PROJECT_YML" | sort -u)

# The literal assigned to `AppGroup.identifier`, anchored to the assignment so
# comments or other `group.*` literals can never be picked up by accident.
SWIFT_ID="$(grep -oE 'static let identifier[[:space:]]*=[[:space:]]*"[^"]*"' "$APP_DB" \
            | grep -oE 'group\.[A-Za-z0-9._-]+' | head -1)"

if [[ ${#YAML_IDS[@]} -eq 0 ]]; then
  echo "❌ No App Group found under an application-groups: block in $PROJECT_YML"
  exit 1
fi
if [[ -z "$SWIFT_ID" ]]; then
  echo "❌ No AppGroup.identifier = \"group.…\" assignment found in $APP_DB"
  exit 1
fi
if [[ ${#YAML_IDS[@]} -gt 1 ]]; then
  echo "❌ Multiple distinct App Groups in $PROJECT_YML; app and widget must share one:"
  printf '   %s\n' "${YAML_IDS[@]}"
  exit 1
fi
if [[ "${YAML_IDS[0]}" != "$SWIFT_ID" ]]; then
  echo "❌ App Group identifier drift:"
  echo "   project.yml entitlement : ${YAML_IDS[0]}"
  echo "   AppGroup.identifier      : $SWIFT_ID"
  echo "   These must match — the app and the widget open the same container."
  exit 1
fi

echo "✅ App Group identifier in sync: $SWIFT_ID"
