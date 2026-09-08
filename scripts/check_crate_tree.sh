#!/bin/bash
# Does the LINKED archive correspond to the crate sources the tree holds?
#
# Answers ONE question the iOS test target structurally cannot: is
# `crate-tree:` in the build manifest equal to a FRESHLY RECOMPUTED
# `git rev-parse HEAD:rust/zeus-core-bridge`?
#
# ── Why this guard exists off-device ───────────────────────────────────────
#
# `Tests/ZeusTests/FrameworkProvenanceTests.swift` asserts that the manifest
# and the generated bindings header agree with EACH OTHER — two write sites of
# one producer run, which is the copy-paste divergence class. It cannot go
# further: `Foundation.Process` does not exist on iOS and that target runs in
# the simulator, so shelling out to git there is unavailable by construction,
# not by omission. Both artifacts agreeing while both are stale is a green over
# there. The recompute is the only thing that separates those cases, and it
# lives here, where git exists.
#
# ── Why crate-tree and not crate-sha ───────────────────────────────────────
#
# crate-sha is HEAD, which moves on commits that never touch the crate.
# Measured at the cut that added this file: `a9f4d36..HEAD` is a single
# test-only commit, so crate-sha moved (a9f4d36 -> 6acd3dd) while the crate
# tree stayed 73d186af. Keyed on crate-sha this guard would red on a
# byte-correct artifact, and — far worse — go green the moment you commit
# anything, which is exactly when nobody is looking.
#
# ── APERTURE ───────────────────────────────────────────────────────────────
#
# `git rev-parse HEAD:<path>` reads the COMMITTED tree object. Uncommitted or
# staged edits under rust/zeus-core-bridge/ are UNMEASURED: you can dirty the
# crate, rebuild, and pass. That gap is named rather than papered over. It is
# reported below as an explicit note when the crate is dirty, so the reading
# travels with the condition that produced it.
#
# Exit codes, three-valued per the runner's contract:
#   0  the archive corresponds to the committed crate sources
#   1  DRIFT — archive and tree disagree; the linked .a is not the tree's crate
#   2  VOID  — could not measure (no artifact, no field, git faulted)

set -u

cd "$(dirname "$0")/.." || { echo "VOID: cannot reach repo root"; exit 2; }

MANIFEST="Frameworks/ZeusCore.xcframework/zeus-build-manifest.txt"
CRATE_PATH="rust/zeus-core-bridge"

# ── the artifact ───────────────────────────────────────────────────────────
[ -f "$MANIFEST" ] || {
  echo "VOID: no manifest at $MANIFEST — Frameworks/ is gitignored, so a fresh"
  echo "      checkout has nothing to measure. Run scripts/build-xcframework.sh"
  echo "      (rustup + both iOS targets + full Xcode, ~5 min warm)."
  exit 2
}

DECLARED="$(grep -m1 '^crate-tree:' "$MANIFEST" | awk '{print $2}')"
[ -n "$DECLARED" ] || {
  echo "VOID: $MANIFEST carries no \`crate-tree:\` line — the artifact predates"
  echo "      the producer emitting it. Rebuild."
  exit 2
}

# ── the control, run ALONE with its rc asserted before any filtering ───────
# A dead git and a healthy-empty result are the same empty string downstream,
# so the producer's status is checked on its own line before the value is used.
ACTUAL=""
rc=0
ACTUAL="$(git rev-parse "HEAD:$CRATE_PATH" 2>/tmp/check_crate_tree.err)" || rc=$?
[ "$rc" -eq 0 ] || {
  echo "VOID: \`git rev-parse HEAD:$CRATE_PATH\` exited $rc — the control never"
  echo "      ran, so any verdict below would be an artifact of the probe."
  sed 's/^/      /' /tmp/check_crate_tree.err 2>/dev/null
  exit 2
}

case "$ACTUAL" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) echo "VOID: recomputed tree '$ACTUAL' is not lowercase hex — the control"
     echo "      is not measuring what this guard claims"; exit 2 ;;
esac
[ "${#ACTUAL}" -eq 40 ] || {
  echo "VOID: recomputed tree is ${#ACTUAL} chars, not a 40-char tree object"
  exit 2
}

# ── vacuity guard ──────────────────────────────────────────────────────────
# The two values must come from different places. If they were ever fed from
# one source, the equality below would hold by construction and prove nothing.
[ -n "$DECLARED" ] && [ -n "$ACTUAL" ] || {
  echo "VOID: one side of the comparison is empty"; exit 2
}

# ── the reading ────────────────────────────────────────────────────────────
if [ "$DECLARED" != "$ACTUAL" ]; then
  echo "DRIFT: the linked archive was built from crate tree"
  echo "         $DECLARED"
  echo "       but the tree holds"
  echo "         $ACTUAL"
  echo "The .a in Frameworks/ does not correspond to $CRATE_PATH as committed."
  echo "A streamed reply in this state is a real token stream through the WRONG"
  echo "binary. Rebuild: scripts/build-xcframework.sh"
  exit 1
fi

# Dirty-crate note. Not a failure — a stated aperture, so the pass is read with
# the condition that produced it rather than as an unqualified green.
DIRTY="$(git status --porcelain -- "$CRATE_PATH" | wc -l | tr -d ' ')"
if [ "$DIRTY" != "0" ]; then
  echo "NOTE: $DIRTY uncommitted path(s) under $CRATE_PATH/ — those edits are"
  echo "      UNMEASURED by this guard, which reads the committed tree object."
  git status --porcelain -- "$CRATE_PATH" | sed 's/^/        /'
fi

echo "OK: archive crate-tree == HEAD:$CRATE_PATH ($ACTUAL)"
exit 0
