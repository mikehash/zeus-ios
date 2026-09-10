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

# ── The comparand's SCOPE is read from project.yml, not written here ───────
# 🔴 RE-PIN, 2026-09-07. This was `SRC_DIR="Sources/ZeusApp"`, a hand-written
#    single directory. `Sources/ZeusCoreFFI/zeus_core_bridge.swift` (the
#    generated UniFFI bindings, checked in and compiled as app source) landed
#    at 35b45ec, the driver compiled it, the tree-side set did not contain it,
#    and the guard reported DRIFT rc=3 — CORRECTLY. The tree had grown a
#    second source root and the guard's aperture had not.
#
#    Re-pinning by appending "Sources/ZeusCoreFFI" would fix this instance and
#    rebuild the same defect for the third directory. The driver's input list
#    is generated FROM project.yml; so is the app target. Reading the scope
#    from the same declaration the build reads makes the two sides move
#    together by construction rather than by anyone remembering.
#
#    Aperture: this parses the `sources:` block of the FIRST target under
#    `targets:` (the app). It is a text parse of YAML, not a YAML parser — if
#    project.yml grows a form this cannot read, the POS control at step 3
#    fires VOID (zero files) rather than reporting a false clean.
#
#    IT DID, AND THE VOID IS WHY THIS BRANCH EXISTS. xcodegen's `sources:`
#    accepts BOTH a bare scalar (`- Sources/ZeusApp`) and a mapping
#    (`- path: … / buildPhase: …`). Bundling the build manifest as a resource
#    needs the mapping form, and the old one-armed rule fed the whole literal
#    line — `path: Frameworks/…` — to `git add`, which answered
#    `pathspec … did not match any files`, rc=128. It VOIDed rather than
#    passing, which is the guard behaving correctly: a parser that silently
#    dropped the entry would have reported a clean tree for a file set it
#    could not see. Both forms are read now, and the `- [a-zA-Z]` bound on the
#    scalar arm keeps a continuation key (`        buildPhase: resources`)
#    from being taken as a path.
SRC_DIRS=()
while read -r _d; do [ -n "$_d" ] && SRC_DIRS+=("$_d"); done < <(
    awk '/^  '"$SCHEME"':$/{t=1; next}
         t && /^    sources:/{s=1; next}
         t && s && /^      - path: /{sub(/^      - path: /,""); print; next}
         t && s && /^      - [a-zA-Z]/{sub(/^      - /,""); print; next}
         t && s && /^    [a-z]/{exit}' project.yml
)
[ "${#SRC_DIRS[@]}" -ge 1 ] || { echo "VOID: no sources: entries parsed from project.yml for target $SCHEME"; exit 2; }

# ── 0b. The tree-identity aperture is the TRACKED half of `sources:` ────────
#
# 🔴 NOT EVERY `sources:` ENTRY IS A SOURCE FILE. The target now lists
# `Frameworks/ZeusCore.xcframework/zeus-build-manifest.txt` as a resource so
# the app can render its own core's provenance on a phone. That path is a
# BUILD PRODUCT inside a gitignored directory: `git add` refuses it (rc=1,
# "ignored by one of your .gitignore files"), the recompute produces nothing,
# and this guard VOIDs — measured, not predicted.
#
# The right aperture is the tracked half, and the reason is not convenience:
# this guard's subject is "did the source tree change since the compile", and
# a build product has no place in a SOURCE identity — its own provenance is
# guarded one file over by `check_crate_tree.sh`, which compares the archive's
# manifest against the worktree tree of the crate that produced it. Folding a
# generated artifact into the source stamp would make every rebuild read as
# source drift.
#
# `git check-ignore` is the discriminator, and the split is PRINTED rather
# than silently applied: an entry vanishing from the aperture is exactly the
# thing that turns a guard into decoration.
TREE_PATHS=()
SKIPPED=()
for _p in "${SRC_DIRS[@]}"; do
    if git check-ignore -q -- "$_p" 2>/dev/null; then SKIPPED+=("$_p"); else TREE_PATHS+=("$_p"); fi
done
[ "${#TREE_PATHS[@]}" -ge 1 ] || { echo "VOID: every sources: entry is git-ignored — nothing to hash"; exit 2; }
[ "${#SKIPPED[@]}" -eq 0 ] || echo "  tree-identity aperture EXCLUDES (git-ignored, build products): ${SKIPPED[*]}"

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
#
# 🔴 AND THE PARAMETER HAS NO SAFE DEFAULT, so there is no default.  Reading
# `${1:-}` as "fall back to the default DerivedData" made a bare invocation
# ANSWER — confidently, about a build the caller never made. Measured three
# separate times on this branch by the author of this file, who had read the
# paragraph above each time: a header documenting a footgun has the durability
# of a comment with no compiler behind it. A guard whose subject is selected by
# an ABSENT argument is not measuring what the caller believes it is measuring,
# and its DRIFT and its OK are equally uninformative.
#
# So: an absent path VOIDs (rc=2), naming the argument. The default DerivedData
# is still reachable — but only by NAMING it, because "audit the tree Xcode.app
# built" is a claim the caller should have to make out loud. An option that can
# be silently defaulted into is indistinguishable, at the output, from one that
# was chosen.
#
# Note the mutation reading: with the fallback restored, a bare call exits 3
# (DRIFT) — the SAME rc as a genuine source-drift verdict on a real build. The
# refusal is rc=2 precisely because "I was not told what to measure" is the
# absence of a measurement, not a measurement that came out badly.
usage() {
    cat >&2 <<'EOF'
usage: check_membership.sh <derivedDataPath>
       check_membership.sh --xcode-default

VOID (rc=2): the DerivedData path is required and has no default.

  <derivedDataPath>   the SAME path the audited build ran under
                      (scripts/check_all.sh forwards its own $1 here)
  --xcode-default     audit the DEFAULT DerivedData — i.e. what Xcode.app
                      built. Explicit on purpose: a real but DIFFERENT
                      subject from a -derivedDataPath build, and picking it
                      by accident is the fault this refusal exists to stop.
EOF
}

DERIVED="${1:-}"
DD_ARGS=()
case "$DERIVED" in
    "")               usage; echo "VOID: no derivedDataPath argument"; exit 2 ;;
    --xcode-default)  DERIVED=""  # deliberate: no -derivedDataPath flag passed
                      echo "  subject: DEFAULT DerivedData (--xcode-default, named by the caller)" ;;
    -*)               usage; echo "VOID: unknown option '$DERIVED'"; exit 2 ;;
    *)                [ -d "$DERIVED" ] || { echo "VOID: derivedDataPath '$DERIVED' is not a directory"; exit 2; }
                      DD_ARGS=(-derivedDataPath "$DERIVED") ;;
esac

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
TREE=$(git ls-files --cached --others --exclude-standard -- "${SRC_DIRS[@]}" \
       | grep '[.]swift$' | sort -u) || tree_rc=$?
[ "$tree_rc" -eq 0 ] || void "git ls-files rc=$tree_rc"
TREE_N=$(printf '%s\n' "$TREE" | grep -c '[.]swift$')
[ "$TREE_N" -gt 0 ] || void "POS control dead: zero .swift files found under ${SRC_DIRS[*]}"

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
    # 🔴 GENERATED INPUTS ARE NOT WORKING-TREE FILES, AND THE VOID WAS ME
    #    ASKING THE WRONG SET. Measured at a63b343: the one stray is
    #    .../Zeus.build/DerivedSources/GeneratedAssetSymbols.swift, emitted by
    #    the asset compiler under OBJROOT. It is a real compiler input, it has
    #    no working-tree counterpart by construction, and `git ls-files` can
    #    never produce it — so comparing it against TREE is a category error,
    #    not drift. The guard was VOID on a file whose absence from the tree is
    #    the correct state.
    #
    #    The repair is NARROW on purpose: drop only what sits under this very
    #    invocation's OBJROOT — the coordinate the build system emitted about
    #    itself, two sections up. Any OTHER absolute path is still a VOID,
    #    because a blanket `grep -v '^/'` would silently discard a real source
    #    living outside ROOT and turn this guard back into the false zero it
    #    was written to replace. Generated count is printed beside the aperture
    #    so it is never invisible.
    GEN=$(printf '%s\n' "$GOT" | grep -c "^$OBJROOT/")
    GOT=$(printf '%s\n' "$GOT" | grep -v "^$OBJROOT/")
    STRAY=$(printf '%s\n' "$GOT" | grep -c '^/')
    [ "$STRAY" -eq 0 ] || void "$STRAY driver input path(s) neither under ROOT=$ROOT nor generated under OBJROOT — cannot normalise"
    GOT_N=$(printf '%s\n' "$GOT" | grep -c '[.]swift$')

    # `written` is DISPLAY ONLY and says so on the line. Time was the retired
    # instrument here: `touch`, `git checkout`, `cp -p` and clock skew all move
    # an mtime with no content change, and content can change under an older
    # stamp. The verdict below is tree identity (§5b). A reader at a DRIFT
    # wants to know WHEN the list was written after being told THAT it is
    # stale — that is the only job this field has.
    printf 'list %-28s inputs=%-3s (+%s generated) tree=%-3s written=%s (display only; verdict = tree identity, §5b)\n' "$ARCH" "$GOT_N" "$GEN" "$TREE_N" "$MT"

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
if [ "${#LISTS[@]}" -gt 1 ]; then
    counts=$(for FL in "${LISTS[@]}"; do tr ' ' '\n' < "$FL" | grep -c '[.]swift$'; done | sort -u | wc -l | tr -d ' ')
    [ "$counts" -eq 1 ] || drift "arch lists DISAGREE on input count — at least one is stale"
fi

# ── 5b. FRESHNESS BY IDENTITY — the leg cardinality could not carry ────────
#
# Membership is a property of an ELEMENT; staleness is a property of the SET,
# and specifically of its CONTENT. Steps 4 and 5 are both blind to a list that
# names every current file while describing a tree whose files have since been
# REWRITTEN — the world measured at da274673, where this guard printed OK over
# a list produced 9h44m and nine rewritten files earlier.
#
# 🔴 mtime IS NOT THE INSTRUMENT. It was the first thing reached for and it is
# a second proxy, wrong in both directions: `git checkout`, `touch`, `cp -p`, a
# clock skew, or a rebuild that rewrites the list unchanged all move a stamp
# with no content change; and content can change under an older stamp. The
# `touch` leg below exists precisely to separate this instrument from that one
# — mtime CANNOT pass it.
#
# Freshness is IDENTITY. The producer (scripts/stamp-sources-tree.sh, a
# post-compile phase of the target) stamps the build with the tree object of
# the sources it compiled, computed from the WORKTREE via a temp index. This
# recomputes the same hash now and compares. Equal = the list describes the
# tree on disk. Different = DRIFT, and the guard can now name exactly what it
# previously had to apologise for.
STAMP="$OBJROOT/zeus-sources-tree.txt"
SEEN_STAMP=0
if [ -f "$STAMP" ]; then
    SEEN_STAMP=1
    DECLARED=$(awk '/^sources-tree:/{print $2; exit}' "$STAMP")
    [ -n "${DECLARED:-}" ] || void "$STAMP carries no \`sources-tree:\` line"

    # Same recipe as the producer. `mktemp -u` — a NAME, not a file: an
    # existing zero-byte index is REJECTED by git (`index file smaller than
    # expected`, rc=128) on both `add` and `write-tree`, and that failure is
    # loud in stderr and invisible in a value-capture. Measured on this box.
    IDX=$(mktemp -u)
    add_rc=0
    GIT_INDEX_FILE="$IDX" git add -- "${TREE_PATHS[@]}" 2>/tmp/membership.stamp.err || add_rc=$?
    ACTUAL=""
    [ "$add_rc" -eq 0 ] && { ACTUAL=$(GIT_INDEX_FILE="$IDX" git write-tree 2>>/tmp/membership.stamp.err) || ACTUAL=""; }
    rm -f "$IDX"

    # VOID, never OK: a recompute that yields no tree is the ABSENCE of a
    # measurement, and reporting it as agreement would be the false green this
    # whole guard exists to refuse.
    [ -n "$ACTUAL" ] || void "worktree tree recompute produced nothing (add rc=$add_rc): $(cat /tmp/membership.stamp.err 2>/dev/null | tr '\n' ' ')"

    if [ "$DECLARED" != "$ACTUAL" ]; then
        echo "DRIFT: the driver input list describes a DIFFERENT source tree than the one on disk."
        echo "  stamped at build time : $DECLARED"
        echo "  worktree now          : $ACTUAL"
        echo "  covered paths         : ${TREE_PATHS[*]}"
        echo "  Every number taken from this build is about code that is no longer here."
        status=3
    else
        echo "FRESH: sources-tree $ACTUAL == stamp (${TREE_PATHS[*]})"
    fi
fi

if [ "${#LISTS[@]}" -le 1 ] && [ "${SEEN_STAMP:-0}" -eq 0 ]; then
    echo "NOTE: ${#LISTS[@]} list — cardinality leg VACUOUS (needs >1) and NO SOURCE STAMP present;"
    echo "      a stale list containing every current file passes here. Rebuild to write the stamp."
fi

# ── 6. NEG control: a needle that cannot be present ────────────────────────
NEEDLE="zzznope-member-$$-$RANDOM"
NEG=$(printf '%s\n' "$TREE" | grep -c "$NEEDLE")
[ "$NEG" -eq 0 ] || void "NEG control alive ($NEG) — the comparison is not discriminating"

[ "$status" -eq 0 ] || exit "$status"
echo "OK: all $TREE_N working-tree .swift files present in ${#LISTS[@]} driver input list(s)"
