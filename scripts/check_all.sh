#!/bin/bash
#
# The runner. Owed since the first guard landed, and the reason it was owed is
# the reason it exists: THREE GUARDS THAT NOTHING INVOKES ARE THREE FILES.
#
# Each of scripts/check_*.sh is individually mutation-proven, and every one of
# those proofs was run BY HAND. A guard's power is the product of its needle and
# its invocation frequency, and the second factor was zero. This file is that
# factor.
#
# ── The discrimination this runner must not lose ───────────────────────────
#
# Every guard here is THREE-VALUED by construction:
#
#     0  the property holds
#     1  the property is BROKEN            -> fix the code
#     2  the INSTRUMENT faulted            -> fix the guard; the code is UNMEASURED
#
# A runner that collapses "non-zero" into "failed" destroys exactly the
# distinction the guards were rewritten to carry. rc=2 is not a weaker rc=1: a
# BROKEN verdict is a measurement, a VOID verdict is the absence of one, and
# they send a reader to different repositories. So this runner tallies them
# SEPARATELY and reports both counts, and its own exit code is
#
#     2 if ANY guard voided   (an unmeasured tree is worse than a red one,
#                              because red is visible and unmeasured is not)
#     1 if any guard broke
#     0 only if every guard ran AND every guard passed
#
# ── Why the guard list is not a glob ────────────────────────────────────────
#
# `scripts/check_*.sh` would silently shrink to zero if this file were moved,
# renamed, or run from a directory where the glob does not match — and a loop
# over zero elements exits 0. That is the corpse-looks-like-a-zero class in its
# purest form: the runner reports total success precisely when it has run
# nothing. The list is therefore EXPLICIT, and the count is asserted against a
# literal below. Adding a guard means editing two lines here — deliberately, so
# that the edit is visible in review rather than absorbed by a wildcard.
#
set -u

cd "$(dirname "$0")/.." || { echo "VOID: cannot reach repo root"; exit 2; }

# The membership guard takes the DerivedData path as a PARAMETER — its own
# header records why: `xcodebuild -showBuildSettings` answers about the
# INVOCATION you give it, so a guard that asks with no path is answering about
# a different build than the one that was gated. Forwarded from $1, and when $1
# is absent the guard reads the DEFAULT DerivedData, which is a real but
# DIFFERENT subject.
#
# 🔴 AND THE FORWARD MUST NOT RESTORE THE DEFAULT ONE LAYER UP.  The membership
# guard now REFUSES a bare invocation (its own header records why: three false
# DRIFTs against a build the caller never made). If this runner papered over
# that by substituting a fallback when $1 is absent, the refusal would be
# perfectly intact and perfectly unreachable — the guard would still never see
# a bare call, and the runner would go on answering about the wrong build. A
# refusal that its only caller defaults past is a comment.
#
# So the requirement propagates: this runner requires the subject too, and
# `--xcode-default` is forwarded VERBATIM rather than translated to an absence.
#
# Usage:  scripts/check_all.sh <derivedDataPath>
#         scripts/check_all.sh --xcode-default
DERIVED="${1:-}"
case "$DERIVED" in
  "") cat >&2 <<'EOF'
usage: check_all.sh <derivedDataPath>
       check_all.sh --xcode-default

The suite contains a guard whose subject is a BUILD, so the suite needs the
build named. There is no default: an unnamed subject is how this suite spent
three cycles auditing a DerivedData tree nobody had built.
EOF
      echo "VOID: no derivedDataPath argument"; exit 2 ;;
esac

GUARDS=(
  "scripts/check_membership.sh${DERIVED:+ $DERIVED}"
  scripts/check_narration_shape.sh
  scripts/check_network_shape.sh
  scripts/check_crate_tree.sh
  scripts/check_separator_debt.sh
)
EXPECTED_GUARDS=5

# ARITY ASSERTION. If the array and the literal disagree, someone added a guard
# without adding it here, or removed one without removing it. Either way the
# suite below is not the suite this file claims to run.
[ "${#GUARDS[@]}" -eq "$EXPECTED_GUARDS" ] || {
  echo "VOID: guard list has ${#GUARDS[@]} entries, expected $EXPECTED_GUARDS"
  exit 2
}

# PRESENCE ASSERTION, before any execution. A missing guard must VOID, not be
# skipped: `for f; do [ -x "$f" ] && "$f"; done` over a deleted file passes
# perfectly, and the deletion of a guard is the single most likely way for one
# to stop protecting anything.
for entry in "${GUARDS[@]}"; do
  # An entry may carry a trailing argument; the guard is the first word.
  set -- $entry
  g="$1"
  [ -f "$g" ] || { echo "VOID: guard missing: $g"; exit 2; }
  [ -x "$g" ] || { echo "VOID: guard not executable: $g"; exit 2; }
done

PASS=0; BROKEN=0; VOID=0
BROKEN_NAMES=(); VOID_NAMES=()

for entry in "${GUARDS[@]}"; do
  set -- $entry
  g="$1"
  echo "──────── $entry"
  # rc read ALONE, on its own line, never after an intervening command and
  # never through a pipe. PIPESTATUS is clobbered by the next command and an
  # empty rc in a report renders as a zero; that fault dies at the SCRIBE, so
  # no upstream probe can catch it.
  rc=0
  "$@" || rc=$?
  case "$rc" in
    0) PASS=$((PASS + 1));     echo "  -> PASS   (rc=0)" ;;
    1) BROKEN=$((BROKEN + 1)); BROKEN_NAMES+=("$g"); echo "  -> BROKEN (rc=1) — the CODE violates the property" ;;
    3) BROKEN=$((BROKEN + 1)); BROKEN_NAMES+=("$g (DRIFT rc=3)"); echo "  -> BROKEN (rc=3) — DRIFT: tree and build artefact disagree" ;;
    2) VOID=$((VOID + 1));     VOID_NAMES+=("$g");   echo "  -> VOID   (rc=2) — the GUARD faulted; tree is UNMEASURED" ;;
    *) VOID=$((VOID + 1));     VOID_NAMES+=("$g (UNDECLARED rc=$rc)"); echo "  -> VOID   (rc=$rc) — UNDECLARED exit code; the runner has no reading for it" ;;
  esac
done

echo "════════ guards=${#GUARDS[@]}  pass=$PASS  broken=$BROKEN  void=$VOID"

# The tally must account for every guard. If it does not, a branch above fell
# through without incrementing anything and the summary is describing a
# different run than the one that happened.
TOTAL=$((PASS + BROKEN + VOID))
[ "$TOTAL" -eq "${#GUARDS[@]}" ] || {
  echo "VOID: tally $TOTAL != ${#GUARDS[@]} guards — the summary is not about this run"
  exit 2
}

if [ "$VOID" -ne 0 ]; then
  printf 'VOID guard: %s\n' "${VOID_NAMES[@]}"
  echo "UNMEASURED: at least one property was not tested. This is not a pass."
  exit 2
fi
if [ "$BROKEN" -ne 0 ]; then
  printf 'BROKEN guard: %s\n' "${BROKEN_NAMES[@]}"
  exit 1
fi

echo "OK: ${#GUARDS[@]} guards ran, ${#GUARDS[@]} passed"
exit 0
