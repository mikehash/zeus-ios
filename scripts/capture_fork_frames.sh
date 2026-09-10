#!/bin/bash
# Flow-frame capture for the fork review. NOT the store set — see
# capture_store_screens.sh for that. This one walks `-zeusStep` and names the
# sha in every filename so a frame can never be re-attached to another commit.
set -u
SHA=$(cd "$(dirname "$0")/.." && git rev-parse --short HEAD)
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEVICE="${ZEUS_CAPTURE_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="ai.novaxai.zeus.mobile"
OUT="$REPO/build/fork-frames"
BAD=2
die() { echo "INSTRUMENT: $*" >&2; exit $BAD; }

# This host has TWO simulators named "iPhone 17 Pro" — a name is not an
# identity, so an explicit UDID overrides and the name path stays strict.
UDID="${ZEUS_CAPTURE_UDID:-}"
[ -n "$UDID" ] || UDID=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json,sys
want=sys.argv[1]; d=json.load(sys.stdin)["devices"]
hits=[x["udid"] for r in d.values() for x in r if x["name"]==want]
if len(hits)!=1: sys.exit(1)
print(hits[0])
' "$DEVICE") || die "no unambiguous simulator named $DEVICE"
echo "device : $DEVICE / $UDID"
echo "sha    : $SHA"

xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

DD="$REPO/build/dd-capture"
xcodebuild -project "$REPO/Zeus.xcodeproj" -scheme Zeus -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DD" build >/tmp/capbuild.log 2>&1 \
  || { tail -25 /tmp/capbuild.log >&2; die "build failed"; }
APP="$DD/Build/Products/Debug-iphonesimulator/Zeus.app"
[ -d "$APP" ] || die "no app at $APP"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || die "install failed"

rm -rf "$OUT"; mkdir -p "$OUT"
shot() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null 2>&1 || die "launch failed: $name"
  sleep 4
  xcrun simctl io "$UDID" screenshot "$OUT/${name}-${SHA}.png" >/dev/null 2>&1 \
    || die "screenshot failed: $name"
  echo "shot   : ${name}-${SHA}.png   args: $*"
}

shot 0-welcome   -zeusStep welcome  -zeusMuteVoice
shot 1-fork      -zeusStep fork     -zeusMuteVoice
shot 2-auth      -zeusStep auth     -zeusMuteVoice
shot 3-routes    -zeusStep routes   -zeusMuteVoice
shot 4-nodes     -zeusStep nodes    -zeusMuteVoice
shot 5-callsign  -zeusStep callsign -zeusMuteVoice
shot 6-summary   -zeusStep done     -zeusMuteVoice
shot 7-home      -zeusSeedCommission -zeusTab zeus  -zeusMuteVoice
shot 8-nodestab  -zeusSeedCommission -zeusTab nodes -zeusMuteVoice
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1

# Distinctness: App Store Connect will accept a set where three files are the
# same screen, and so will a human scrolling a Discord thread.
python3 - "$OUT" <<'PY'
import sys,hashlib,pathlib,collections
d=pathlib.Path(sys.argv[1]); h=collections.defaultdict(list)
for p in sorted(d.glob("*.png")):
    h[hashlib.sha256(p.read_bytes()).hexdigest()[:12]].append(p.name)
dupes={k:v for k,v in h.items() if len(v)>1}
print(f"frames : {sum(len(v) for v in h.values())}  distinct: {len(h)}")
for k,v in dupes.items(): print(f"DUPE   : {k} -> {v}")
sys.exit(3 if dupes else 0)
PY
echo "rc=$?"
