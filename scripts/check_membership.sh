#!/bin/bash
# Membership check for the Zeus target's Swift sources.
#
# Answers ONE question: was every source file in the working tree actually
# handed to the compiler? A target compiles perfectly well with a new file
# sitting outside it, and rc=0 over the target is an aggregate that cannot see
# the omission.
#
# ── Two faults this replaces, both measured ────────────────────────────────
#
# 1. GLOB + head -1 SELECTED A STALE DerivedData HASH.  The old probe globbed
#    `DerivedData/Zeus-*/…/Zeus.SwiftFileList | head -1` and read a list built
#    6.5h earlier: 8 inputs, the file under test absent, verdict "not a member"
#    — a FALSE ZERO. A path glob is a claim about the filesystem written by the
#    reader. `xcodebuild -showBuildSettings` is a coordinate written by the
#    build system about the invocation you are about to run. When a path is
#    load-bearing, prefer the instrument that emits its own.
#
# 2. THE POSITIVE CONTROL COULD NOT HAVE CAUGHT IT.  A stale artefact contains
#    every OLD file, so any control drawn from pre-existing code is alive in it
#    BY CONSTRUCTION. Membership cannot detect staleness: staleness is a
#    property of the SET, membership is a property of an ELEMENT. Only
#    CARDINALITY or RECENCY sees it — hence the count comparison below, and
#    hence the mtime is printed as a corroborator and never as the verdict.
#
# ── The comparand ──────────────────────────────────────────────────────────
#
# NOT `git ls-files`. The SwiftFileList enumerates the WORKING TREE; ls-files
# enumerates the INDEX. They agree only when nothing is uncommitted — and the
# state you build in is precisely the state where something is. Comparing them
# false-reds on every newly added file, which trains you to ignore the guard.
# `--cached --others --exclude-standard` is index-free in effect: tracked plus
# untracked-not-ignored, i.e. the same set the compiler was handed.
#
# rc: 0 pass · 2 VOID (instrument could not run) · 3 DRIFT (real mismatch)

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || { echo "VOID: cannot cd to repo root"; exit 2; }

SCHEME="Zeus"
DEST="generic/platform=iOS Simulator"
SRC_DIR="Sources/ZeusApp"

void() { echo "VOID: $*"; exit 2; }
drift() { echo "DRIFT: $*"; exit 3; }

# ── 1. Ask the build system for its own coordinate ─────────────────────────
settings_rc=0
settings=$(xcodebuild -scheme "$SCHEME" -destination "$DEST" \
                      -configuration Debug -showBuildSettings 2>/tmp/membership.err) \
    || settings_rc=$?
[ "$settings_rc" -eq 0 ] || void "showBuildSettings rc=$settings_rc ($(wc -c </tmp/membership.err) B stderr)"

OBJROOT=$(printf '%s\n' "$settings" | awk -F' = ' '/^ *OBJROOT = /{print $2; exit}')
[ -n "${OBJROOT:-}" ] || void "OBJROOT absent from build settings"
[ -d "$OBJROOT" ] || void "OBJROOT does not exist on disk: $OBJROOT (build at least once)"

# ── 2. Locate the driver input list UNDER that coordinate ──────────────────
# No `head -1`: if more than one arch list exists they must AGREE, and a
# disagreement is itself the signal. We enumerate and count, never sample.
mapfile -t LISTS < <(find "$OBJROOT" -name "$SCHEME.SwiftFileList" 2>/dev/null | sort)
[ "${#LISTS[@]}" -ge 1 ] || void "no $SCHEME.SwiftFileList under OBJROOT (target never built here)"

# ── 3. The comparand — working tree, index-free ────────────────────────────
tree_rc=0
TREE=$(git ls-files --cached --others --exclude-standard -- "$SRC_DIR" \
       | grep '[.]swift$' | sed 's|.*/||' | sort -u) || tree_rc=$?
[ "$tree_rc" -eq 0 ] || void "git ls-files rc=$tree_rc"
TREE_N=$(printf '%s\n' "$TREE" | grep -c '[.]swift$')
[ "$TREE_N" -gt 0 ] || void "POS control dead: zero .swift files found under $SRC_DIR"

# ── 4. Compare every list, print the aperture beside every number ──────────
status=0
for FL in "${LISTS[@]}"; do
    MT=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$FL")
    ARCH=$(printf '%s' "$FL" | sed -n 's|.*/\([^/]*\)/[^/]*$|\1|p')
    GOT=$(tr ' ' '\n' < "$FL" | sed 's|.*/||' | grep '[.]swift$' | sort -u)
    GOT_N=$(printf '%s\n' "$GOT" | grep -c '[.]swift$')

    printf 'list %-28s inputs=%-3s tree=%-3s mtime=%s\n' "$ARCH" "$GOT_N" "$TREE_N" "$MT"

    MISSING=$(comm -13 <(printf '%s\n' "$GOT") <(printf '%s\n' "$TREE"))
    EXTRA=$(comm -23 <(printf '%s\n' "$GOT") <(printf '%s\n' "$TREE"))
    [ -n "$MISSING" ] && { echo "  NOT COMPILED: $(printf '%s' "$MISSING" | tr '\n' ' ')"; status=3; }
    [ -n "$EXTRA" ]   && { echo "  COMPILED BUT ABSENT FROM TREE (stale list?): $(printf '%s' "$EXTRA" | tr '\n' ' ')"; status=3; }
done

# ── 5. Cardinality across lists — the leg that sees staleness ──────────────
if [ "${#LISTS[@]}" -gt 1 ]; then
    counts=$(for FL in "${LISTS[@]}"; do tr ' ' '\n' < "$FL" | grep -c '[.]swift$'; done | sort -u | wc -l | tr -d ' ')
    [ "$counts" -eq 1 ] || drift "arch lists DISAGREE on input count — at least one is stale"
fi

# ── 6. NEG control: a needle that cannot be present ────────────────────────
NEEDLE="zzznope-member-$$-$RANDOM"
NEG=$(printf '%s\n' "$TREE" | grep -c "$NEEDLE")
[ "$NEG" -eq 0 ] || void "NEG control alive ($NEG) — the comparison is not discriminating"

[ "$status" -eq 0 ] || exit "$status"
echo "OK: all $TREE_N working-tree .swift files present in ${#LISTS[@]} driver input list(s)"
