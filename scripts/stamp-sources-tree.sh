#!/bin/bash
# Producer half of the source-freshness stamp.
#
# Runs as a post-compile phase of the Zeus target, i.e. in the SAME invocation
# that writes `$SCHEME.SwiftFileList`. It records the IDENTITY of the sources
# that invocation compiled, so `check_membership.sh` can later ask whether the
# list it is reading still describes the tree on disk.
#
# ── Why identity and not time ──────────────────────────────────────────────
#
# The leg this replaces compared the list's mtime against the newest source.
# mtime is a proxy and it is wrong in both directions: `git checkout`, `touch`,
# `cp -p`, a clock skew, or a rebuild that rewrites the list unchanged all move
# a stamp with no content change; and content can change under an older stamp
# (a checkout of an older revision writes new bytes with whatever mtime the
# filesystem hands it). Freshness is IDENTITY. This is the recipe
# `check_crate_tree.sh` already runs on, one directory over.
#
# ── Why the WORKTREE tree and not `HEAD:Sources` ───────────────────────────
#
# `git rev-parse HEAD:Sources` reads the COMMITTED tree. The state you build in
# is precisely the state where something is uncommitted, so keying on HEAD
# makes every dirty build read as drift and trains the reader to ignore the
# guard — and, worse, a build of uncommitted work would be stamped with the
# identity of code it did not compile. A temp index gives the tree object of
# the files as they are ON DISK, which is what the compiler actually read.
#
# 🔴 `mktemp` MUST BE `-u`. Measured on this box: `GIT_INDEX_FILE=$(mktemp)`
# hands git an EXISTING ZERO-BYTE file, and git rejects it —
#   `fatal: …: index file smaller than expected`, rc=128 —
# for BOTH `git add` and `git write-tree`. The failure is loud in stderr and
# INVISIBLE in a pipeline that only reads stdout: `TREE` comes back empty and
# the next command interpolates it into `":Sources"`, which fails with a
# different message about a different subject. `-u` emits a NAME that does not
# exist, which is what git wants.
set -u

# Never fail the build. A stamp that cannot be written must leave NO stamp:
# the consumer treats an absent stamp as VOID (unmeasured), which is the honest
# verdict, whereas a half-written or defaulted stamp would be a false OK.
STAMP_DIR="${OBJROOT:-}"
if [ -z "$STAMP_DIR" ] || [ ! -d "$STAMP_DIR" ]; then
    echo "warning: stamp-sources-tree: no OBJROOT — membership guard will read VOID"
    exit 0
fi

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "warning: stamp-sources-tree: cannot cd $ROOT"; exit 0; }

command -v git >/dev/null 2>&1 || {
    echo "warning: stamp-sources-tree: no git on PATH — membership guard will read VOID"
    exit 0
}

# The path the stamp claims to cover. Parsed from the same `sources:` block the
# consumer parses, so producer and consumer cannot disagree about the aperture.
SRC_DIRS=()
while read -r _d; do [ -n "$_d" ] && SRC_DIRS+=("$_d"); done < <(
    awk '/^  Zeus:$/{t=1; next}
         t && /^    sources:/{s=1; next}
         t && s && /^      - path: /{sub(/^      - path: /,""); print; next}
         t && s && /^      - [a-zA-Z]/{sub(/^      - /,""); print; next}
         t && s && /^    [a-z]/{exit}' project.yml
)
[ "${#SRC_DIRS[@]}" -ge 1 ] || {
    echo "warning: stamp-sources-tree: no sources: parsed — membership guard will read VOID"
    exit 0
}

# THE APERTURE IS THE TRACKED HALF, and it is derived HERE by the same rule the
# consumer uses — not copied as a value. A shared value is what the `2a2168cd`
# hardcode was; a shared RULE run twice is the comparison. `sources:` now
# carries a build product (the bundled core manifest) which `git add` refuses
# as ignored, and a producer that fed it would emit no stamp at all — the
# consumer would then read VOID forever and nobody would see a source change.
TREE_PATHS=()
for _p in "${SRC_DIRS[@]}"; do
    git check-ignore -q -- "$_p" 2>/dev/null || TREE_PATHS+=("$_p")
done
[ "${#TREE_PATHS[@]}" -ge 1 ] || {
    echo "warning: stamp-sources-tree: every sources: entry is git-ignored — membership guard will read VOID"
    exit 0
}

IDX=$(mktemp -u)                       # -u: a NAME, not a file. See above.
add_rc=0
GIT_INDEX_FILE="$IDX" git add -- "${TREE_PATHS[@]}" 2>/dev/null || add_rc=$?
tree=""
if [ "$add_rc" -eq 0 ]; then
    tree=$(GIT_INDEX_FILE="$IDX" git write-tree 2>/dev/null) || tree=""
fi
rm -f "$IDX"

if [ -z "$tree" ]; then
    echo "warning: stamp-sources-tree: write-tree produced nothing (add rc=$add_rc) — membership guard will read VOID"
    exit 0
fi

{
    printf 'sources-tree: %s\n' "$tree"
    printf 'covers: %s\n' "${SRC_DIRS[*]}"
    printf 'stamped: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAMP_DIR/zeus-sources-tree.txt"

echo "stamp-sources-tree: $tree (${SRC_DIRS[*]})"
