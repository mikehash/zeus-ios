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
#
# 🔴 THE COORDINATE IS INVOCATION-SCOPED, NOT PROJECT-SCOPED. A bare
# -showBuildSettings answers about the DEFAULT DerivedData. If the build being
# audited ran under -derivedDataPath, this resolves a DIFFERENT OBJROOT and the
# guard reports NOT COMPILED for files that were compiled perfectly well —
# measured: it flagged GatewayConfig.swift while the real list read 12/12 with
# the file present. That is a FALSE DRIFT, the exact failure mode this guard was
# written to replace, reintroduced one layer up: the tool answers about itself,
# but only about the invocation you actually gave it.
#
# So the derived-data path is a PARAMETER. Pass the same one the build used.
DERIVED="${1:-}"
DD_ARGS=()
[ -n "$DERIVED" ] && DD_ARGS=(-derivedDataPath "$DERIVED")

settings_rc=0
settings=$(xcodebuild -scheme "$SCHEME" -destination "$DEST" \
                      ${DD_ARGS[@]+"${DD_ARGS[@]}"} \
                      -configuration Debug -showBuildSettings 2>/tmp/membership.err) \
    || settings_rc=$?
[ "$settings_rc" -eq 0 ] || void "showBuildSettings rc=$settings_rc ($(wc -c </tmp/membership.err) B stderr)"

OBJROOT=$(printf '%s\n' "$settings" | awk -F' = ' '/^ *OBJROOT = /{print $2; exit}')
[ -n "${OBJROOT:-}" ] || void "OBJROOT absent from build settings"
[ -d "$OBJROOT" ] || void "OBJROOT does not exist on disk: $OBJROOT (build at least once)"

# ── 2. Locate the driver input list UNDER that coordinate ──────────────────
# No `head -1`: if more than one arch list exists they must AGREE, and a
# disagreement is itself the signal. We enumerate and count, never sample.
# NOT `mapfile`: it is bash 4, and this file is executable so its SHEBANG picks
# the interpreter — /bin/bash on a stock mac is 3.2.57. `mapfile` there dies at
# ENUMERATION with rc=1, i.e. OUTSIDE this script's own contract (0/2/3), so a
# consumer keying on -eq 3 reads a dead guard as a pass.
LISTS=()
while read -r _l; do LISTS+=("$_l"); done < <(find "$OBJROOT" -name "$SCHEME.SwiftFileList" 2>/dev/null | sort)
[ "${#LISTS[@]}" -ge 1 ] || void "no $SCHEME.SwiftFileList under OBJROOT (target never built here)"

# ── 3. The comparand — working tree, index-free ────────────────────────────
tree_rc=0
TREE=$(git ls-files --cached --others --exclude-standard -- "$SRC_DIR" \
       | grep '[.]swift$' | sort -u) || tree_rc=$?
[ "$tree_rc" -eq 0 ] || void "git ls-files rc=$tree_rc"
TREE_N=$(printf '%s\n' "$TREE" | grep -c '[.]swift$')
[ "$TREE_N" -gt 0 ] || void "POS control dead: zero .swift files found under $SRC_DIR"

# ── 4. Compare every list, print the aperture beside every number ──────────
status=0
for FL in "${LISTS[@]}"; do
    MT=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$FL")
    ARCH=$(printf '%s' "$FL" | sed -n 's|.*/\([^/]*\)/[^/]*$|\1|p')
    GOT=$(tr ' ' '\n' < "$FL" | grep '[.]swift$' | sed "s|^$ROOT/||" | sort -u)
    # PATHS, not basenames. `sed 's|.*/||'` collapsed two files sharing a
    # basename in different directories into one member, so the count
    # comparison passed over a missing file. Zero members while Sources/ZeusApp
    # is flat; live the day it grows a subdirectory, and nothing said so.
    # If a driver path did not sit under ROOT the strip is a no-op and every
    # comparison below mismatches — VOID rather than report a false DRIFT.
    STRAY=$(printf '%s\n' "$GOT" | grep -c '^/')
    [ "$STRAY" -eq 0 ] || void "$STRAY driver input path(s) not under ROOT=$ROOT — cannot normalise"
    GOT_N=$(printf '%s\n' "$GOT" | grep -c '[.]swift$')

    printf 'list %-28s inputs=%-3s tree=%-3s mtime=%s\n' "$ARCH" "$GOT_N" "$TREE_N" "$MT"

    MISSING=$(comm -13 <(printf '%s\n' "$GOT") <(printf '%s\n' "$TREE"))
    EXTRA=$(comm -23 <(printf '%s\n' "$GOT") <(printf '%s\n' "$TREE"))
    [ -n "$MISSING" ] && { echo "  NOT COMPILED: $(printf '%s' "$MISSING" | tr '\n' ' ')"; status=3; }
    [ -n "$EXTRA" ]   && { echo "  COMPILED BUT ABSENT FROM TREE (stale list?): $(printf '%s' "$EXTRA" | tr '\n' ' ')"; status=3; }
done

# ── 5. Cardinality across lists — the leg that sees staleness ──────────────
# APERTURE: this leg needs TWO lists to compare, so at n=1 it does not run and
# the guard's power drops to step 4 alone — which catches a stale list that
# OMITS a tree file (the case actually hit) but NOT one that is stale and
# happens to contain every current file. That world passes silently, so at n=1
# we say so in the output rather than printing a bare OK.
if [ "${#LISTS[@]}" -le 1 ]; then
    echo "NOTE: ${#LISTS[@]} list — cardinality leg VACUOUS (needs >1); a stale list containing every current file passes here"
fi
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
