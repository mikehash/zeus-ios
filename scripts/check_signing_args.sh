#!/usr/bin/env bash
#
# check_signing_args.sh — put a compiler behind "both xcodebuild invocations
# carry the App Store Connect account".
#
# INCIDENT (2026-09-10, Zeus100 running build-device.sh on the coordinator Mac).
# Both `xcodebuild archive` and `xcodebuild -exportArchive` passed
# `-allowProvisioningUpdates` and NOT the ASC key. The flag says "you may mint a
# provisioning profile"; with no account there is nothing to mint WITH. The
# script's own preflight had already validated all three credentials — it just
# never handed them to the tool that signs. The 3 August chain that worked
# passed them on both invocations.
#
# WHY THIS IS A SOURCE CENSUS AND NOT A BEHAVIOURAL TEST: reaching the second
# invocation requires a real archive, i.e. Xcode, a Team ID and 2-5 minutes.
# That was proven ONCE by hand with an argv-capturing shim (both invocations
# carried -authenticationKeyIssuerID; a non-TestFlight run carried zero). This
# guard is the cheap standing check that the arrangement does not regress.
#
# THE NEEDLE IS THE ISSUER ID, deliberately. `-authenticationKeyPath` could be
# satisfied by a path that does not exist and `-authenticationKeyID` by an
# empty string; the issuer is the one of the three the preflight reads from a
# file it has already asserted is non-empty (build-device.sh, `issuer_id`).
#
# Exit codes
#   0  both invocations carry the account
#   1  an invocation lost it
#   2  instrument fault (file missing, or a positive control is dead)
set -uo pipefail

cd "$(dirname "$0")/.." || { echo "VOID: cannot reach repo root"; exit 2; }

S="scripts/build-device.sh"
[ -f "$S" ] || { echo "VOID: $S absent"; exit 2; }

# ── Positive controls, in the SAME read as the verdict ─────────────────────
# A zero-hit census is a statement about the needle unless something with a
# known-present shape is counted beside it.
POS_INVOCATIONS=$(grep -c '^xcodebuild ' "$S")
POS_ISSUER_FILE=$(grep -c 'issuer_id' "$S")
[ "$POS_INVOCATIONS" -eq 2 ] || {
  echo "VOID: expected exactly 2 top-level xcodebuild invocations, found $POS_INVOCATIONS"
  echo "      (the guard's whole shape assumes archive + exportArchive)"
  exit 2; }
[ "$POS_ISSUER_FILE" -ge 1 ] || {
  echo "VOID: positive control dead — 'issuer_id' not read anywhere in $S"; exit 2; }

# ── The verdict ────────────────────────────────────────────────────────────
# The args are passed as an array expansion, so the census is of the ARRAY
# REFERENCE beside each invocation, plus the array's single definition.
# CODE LINES ONLY. The block above documents its own array by name, so a
# whole-file needle counts the EXPLANATION as a call site — the fifth time in
# this branch that a census hit the prose written to justify it. Strip comments
# first, and keep a control proving the stripper did not eat everything.
CODE=$(grep -v '^[[:space:]]*#' "$S")
[ -n "$CODE" ] || { echo "VOID: comment stripper returned nothing"; exit 2; }

ARGS_DEF=$(printf '%s\n' "$CODE" | grep -c 'ASC_XCODEBUILD_ARGS=($')
ARGS_USE=$(printf '%s\n' "$CODE" | grep -c 'ASC_XCODEBUILD_ARGS\[@\]')
ISSUER_DEF=$(printf '%s\n' "$CODE" | grep -c -- '-authenticationKeyIssuerID')

FAIL=0
[ "$ISSUER_DEF" -eq 1 ] || { echo "FAIL: -authenticationKeyIssuerID appears $ISSUER_DEF times, expected 1 (in the array)"; FAIL=1; }
[ "$ARGS_DEF"   -eq 1 ] || { echo "FAIL: ASC_XCODEBUILD_ARGS defined $ARGS_DEF times, expected 1"; FAIL=1; }
[ "$ARGS_USE"   -eq 2 ] || { echo "FAIL: ASC_XCODEBUILD_ARGS expanded at $ARGS_USE sites, expected 2 (both xcodebuild invocations)"; FAIL=1; }

# The `+` guard is not style: this is bash 3.2 under `set -u`, where expanding
# an EMPTY array is an unbound-variable error. Without it EVERY non-TestFlight
# build dies. Measured: bare form rc=1 "A[@]: unbound variable".
UNGUARDED=$(printf '%s\n' "$CODE" | grep -c '[^+]"\${ASC_XCODEBUILD_ARGS\[@\]}"')
[ "$UNGUARDED" -eq 0 ] || {
  echo "FAIL: $UNGUARDED unguarded array expansion(s) — bash 3.2 + set -u kills every non-TestFlight build"
  FAIL=1; }

[ "$FAIL" -eq 0 ] || exit 1
echo "OK: both xcodebuild invocations carry the ASC account · array defined 1, expanded 2 · POS invocations=$POS_INVOCATIONS issuer_id reads=$POS_ISSUER_FILE"
