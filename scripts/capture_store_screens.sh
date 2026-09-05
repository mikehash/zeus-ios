#!/bin/bash
#
# App Store screenshot capture — iPhone only, deterministic, self-verifying.
#
# ── WHY A SCRIPT AND NOT A HUMAN WITH A SIMULATOR ─────────────────────────
#
# Store assets are re-shot every time the UI moves, and a set shot by hand is
# unreproducible: different scroll offsets, different tab, different clock.
# Worse, App Store Connect will accept a set where three files are the SAME
# SCREEN — nothing on the upload path compares them. So the capture must be
# scripted AND the script must assert its own output is what it claims.
#
# ── THE FAILURE THIS SCRIPT EXISTS TO REPORT ──────────────────────────────
#
# `simctl launch` with a bad argument does not fail. `LaunchArgs.initialTab`
# falls back to `.zeus` on an unrecognised value BY DESIGN (a typo should
# photograph the wrong screen loudly, not crash). The consequence is that a
# typo'd `-zeusTab sesion` produces a complete, well-formed, correctly-sized
# set of PNGs in which every frame is the ZEUS tab. Every property a naive
# check tests — file exists, non-zero bytes, 1320x2868 — is GREEN on that set.
#
# So the only honest verification is DISTINCTNESS: the frames this script
# claims are different screens must differ from each other. That check is at
# the bottom and it is the reason this file is not four `simctl` lines.
#
# ── APERTURE ──────────────────────────────────────────────────────────────
#
# This photographs a SEEDED app. `-zeusSeedCommission` walks past the
# commissioning gate, so frames 2..4 prove the console renders GIVEN a
# commission — they prove nothing about the flow that produces one. Frame 1
# is captured with NO arguments for exactly that reason: it is the only frame
# in the set that photographs the real cold-start path.
#
# The device is iPhone 17 Pro Max (1320x2868 = the 6.9" class), which is the
# only display size App Store Connect requires for a submission whose
# TARGETED_DEVICE_FAMILY is "1". iPad is not captured because the app does
# not claim iPad — see project.yml and docs/STORE-UPLOAD-CHECKLIST.md.
#
set -uo pipefail

DEVICE="${ZEUS_CAPTURE_DEVICE:-iPhone 17 Pro Max}"
BUNDLE_ID="com.zeus.Zeus"
OUT="${ZEUS_CAPTURE_OUT:-$(cd "$(dirname "$0")/.." && pwd)/build/store-screenshots}"
DD="${ZEUS_CAPTURE_DERIVED:-/tmp/zeus-store-capture}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Three-valued, same convention as scripts/check_*.sh:
#   0 = the set is good   1 = the set is BAD   2 = the INSTRUMENT faulted
INSTRUMENT_FAULT=2
BAD=1

die_instrument() { echo "VOID: $*" >&2; exit $INSTRUMENT_FAULT; }
die_bad()        { echo "FAIL: $*" >&2; exit $BAD; }

command -v xcrun >/dev/null || die_instrument "xcrun not on PATH"

# ── Resolve the device to a UDID ──────────────────────────────────────────
# `simctl` accepts a NAME, and a name can be ambiguous — this host has two
# "iPhone 17 Pro Max" runtimes. Resolving to a UDID here means the frames and
# the assertions below are about ONE device, and the udid is printed so the
# aperture travels with the artefacts.
UDID=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json,sys
want=sys.argv[1]
d=json.load(sys.stdin)["devices"]
hits=[(rt,dev) for rt,devs in d.items() for dev in devs if dev["name"]==want]
if not hits: sys.exit(3)
hits.sort(key=lambda h: h[0])
print(hits[-1][1]["udid"])
' "$DEVICE") || die_instrument "no available simulator named '$DEVICE'"

echo "device : $DEVICE"
echo "udid   : $UDID"
echo "out    : $OUT"

xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# ── Build ─────────────────────────────────────────────────────────────────
# DEBUG configuration on purpose: every LaunchArgs member is `#if DEBUG`, so
# a release build ignores the arguments and would photograph screen one four
# times. That is the same defect as the typo, arriving from the build config
# instead of the argv — and the distinctness check below catches both.
echo "building (Debug — LaunchArgs is #if DEBUG) ..."
xcodebuild -project "$REPO/Zeus.xcodeproj" -scheme Zeus -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DD" build > "$DD.build.log" 2>&1 \
  || { tail -20 "$DD.build.log" >&2; die_instrument "build failed, see $DD.build.log"; }

APP="$DD/Build/Products/Debug-iphonesimulator/Zeus.app"
[ -d "$APP" ] || die_instrument "no app at $APP"

# The icon must be IN the artefact being photographed. A store set shot from a
# build with no Assets.car is a set for an app that cannot be submitted.
[ -f "$APP/Assets.car" ] || die_bad "no Assets.car in the captured build — the icon is absent"

xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || die_instrument "install failed"

mkdir -p "$OUT" || die_instrument "cannot create $OUT"
rm -f "$OUT"/*.png

# ── Frames ────────────────────────────────────────────────────────────────
# name|launch args
FRAMES=(
  "1-commissioning|"
  "2-zeus|-zeusSeedCommission -zeusTab zeus"
  "3-session|-zeusSeedCommission -zeusTab session"
  "4-nodes|-zeusSeedCommission -zeusTab nodes"
)

for entry in "${FRAMES[@]}"; do
  name="${entry%%|*}"; args="${entry#*|}"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  sleep 1
  # shellcheck disable=SC2086
  xcrun simctl launch "$UDID" "$BUNDLE_ID" $args >/dev/null 2>&1 \
    || die_instrument "launch failed for $name"
  sleep 4
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1 \
    || die_instrument "screenshot failed for $name"
  echo "captured $name.png"
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1

# ── The AX5 set — NOT a store asset, an OBSERVATION ───────────────────────
#
# Every accessibility claim on this branch up to now rested on arithmetic:
# `UIFontMetrics` point sizes, `UIFont.lineHeight` ratios, and an explicit
# aperture line saying "not a measurement of a laid-out Text". `simctl ui
# <udid> content_size` is the instrument that was missing. These frames are
# the first time the AX5 layout has been RENDERED on this branch.
#
# They are captured into a separate directory and are not uploaded. Their
# job is to be looked at, and to prove one thing mechanically: that the app
# responds to the setting at all. Mechanically here means "when this script
# is run" — not "when the suite is run". An app that ignored Dynamic Type entirely
# would produce an AX5 frame IDENTICAL to its default frame — and that is a
# collision, which the verifier already reports.
AXOUT="$OUT/../store-screenshots-ax5"
mkdir -p "$AXOUT"; rm -f "$AXOUT"/*.png
xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large >/dev/null 2>&1 \
  || die_instrument "simctl ui content_size not supported on this host"
for entry in "${FRAMES[@]:1}"; do
  name="${entry%%|*}"; args="${entry#*|}"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  sleep 1
  # shellcheck disable=SC2086
  xcrun simctl launch "$UDID" "$BUNDLE_ID" $args >/dev/null 2>&1 \
    || die_instrument "AX5 launch failed for $name"
  sleep 4
  xcrun simctl io "$UDID" screenshot "$AXOUT/$name.png" >/dev/null 2>&1 \
    || die_instrument "AX5 screenshot failed for $name"
  echo "captured ax5/$name.png"
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
# RESTORE. A left-over AX5 setting is sticky across boots and would silently
# poison the next capture run — the frames would still be well-formed.
xcrun simctl ui "$UDID" content_size large >/dev/null 2>&1
now=$(xcrun simctl ui "$UDID" content_size 2>/dev/null)
[ "$now" = "large" ] || die_instrument "content_size not restored (now: $now)"

# ── The checks that make the sets a measurement ───────────────────────────
echo "--- store set ---"
python3 "$REPO/scripts/verify_store_screens.py" "$OUT" || exit $?
echo "--- ax5 set ---"
python3 "$REPO/scripts/verify_store_screens.py" "$AXOUT" || exit $?

# The cross-set leg: same tab, two content sizes, MUST differ.
#
# SCOPE, so nobody looks for this where it is not: this is an OBSERVATION
# made by this script, not a leg in the suite. `xcodebuild test` does not
# run it and never will — the 200 tests in the suite assert on derived
# numbers (point sizes, line heights, plist values), and none of them has a
# laid-out view as its subject. That aperture, stated on every accessibility
# commit since f4e8152, is closed HERE, by a shell script somebody has to
# invoke, on a machine with a simulator. Calling it an assertion invites the
# next reader to grep the test target for it and conclude it was deleted.
echo "--- default vs AX5, same tab ---"
X="$OUT/../.zeus-axcmp"; rm -rf "$X"; mkdir -p "$X"
cp "$OUT/2-zeus.png"   "$X/a-default.png"
cp "$AXOUT/2-zeus.png" "$X/b-ax5.png"
python3 "$REPO/scripts/verify_store_screens.py" "$X" || {
  echo "FAIL: the ZEUS tab renders IDENTICALLY at default and AX5 — the app is" >&2
  echo "      not responding to Dynamic Type at all." >&2
  rm -rf "$X"; exit $BAD
}
rm -rf "$X"

echo "OK: $(ls "$OUT"/*.png | wc -l | tr -d ' ') store frames + $(ls "$AXOUT"/*.png | wc -l | tr -d ' ') AX5 frames, all distinct"
exit 0
