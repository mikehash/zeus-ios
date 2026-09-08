#!/bin/bash
# Shot-only leg: assumes the app is ALREADY installed by capture_fork_frames.sh.
# Split out because the xcodebuild leg dominates wall-clock and a killed run
# should not cost the build again. Not a substitute for the full script — it
# cannot prove the installed binary matches HEAD, so it takes the sha from git
# and the CALLER owns that claim.
set -u
SHA=$(cd "$(dirname "$0")/.." && git rev-parse --short HEAD)
REPO=$(cd "$(dirname "$0")/.." && pwd)
UDID="${ZEUS_CAPTURE_UDID:?set ZEUS_CAPTURE_UDID}"
BUNDLE_ID="com.zeus.Zeus"
OUT="$REPO/build/fork-frames"
mkdir -p "$OUT"
shot() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null 2>&1 || { echo "LAUNCH FAIL $name" >&2; return 2; }
  sleep 3
  xcrun simctl io "$UDID" screenshot "$OUT/${name}-${SHA}.png" >/dev/null 2>&1 || { echo "SHOT FAIL $name" >&2; return 2; }
  echo "shot: ${name}-${SHA}.png  args: $*"
}
for spec in "$@"; do
  eval "shot $spec"
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
