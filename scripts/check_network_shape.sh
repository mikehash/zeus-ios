#!/usr/bin/env bash
#
# check_network_shape.sh — put a compiler behind the "the unit tests open no
# sockets" claim.
#
# INCIDENT (2026-09-02, zeus106 + Zeus100). A launch report claimed "a census
# leg proving the suite opens zero sockets". No such assertion existed. The
# property was real but was carried ONLY by a doc comment at the top of
# HTTPTransportTests.swift — prose with nothing behind it. Zeus100's tree-wide
# grep found `URLSession` in exactly two files with BOTH hits in doc comments,
# and reported it. He was right, and the row convicted the report rather than
# the tree.
#
# The property is worth keeping structurally: every codec leg takes its input
# as a parameter, so the suite is pure by CONSTRUCTION. The first test that
# constructs a URLSession makes the suite network-dependent without changing a
# single assertion — it will still be green, on a good day.
#
# WHAT THIS PINS
#   1. No test source references URLSession on a CODE line (doc comments
#      naming it are fine — that is what documented the property).
#   2. URLSession has at least one production site in HTTPTransport.swift.
#
# NEEDLE BOUNDARIES (2026-09-02, Zeus100's mutant). The first cut of this
# guard counted a bare substring, so `URLSessionX_MUT` matched and the guard
# read GREEN with the client renamed away. I added a RIGHT boundary and
# published it. Zeus100 then ran the mirrored mutant — `MyURLSession` — and it
# SURVIVED: a right boundary with no left one still matches the suffix of a
# prefixed identifier. Every real URLSession was gone from the client and the
# `>= 1` prod leg stayed green. The needle now carries BOTH boundaries,
# `(^|[^A-Za-z0-9_])URLSession([^A-Za-z0-9_]|$)`, which also fixes the
# false-RED direction: a test naming `FakeURLSessionStub` is a different class
# and no longer trips a guard about this one.
#
# Comment stripping, and the bound I got WRONG first (2026-09-02, Zeus100).
# The header used to say a trailing comment "can only produce a FALSE POSITIVE
# (a refusal), never a false clear", as though the direction made it harmless.
# It does not. His fixture was `let z = 1  // we deliberately avoid URLSession
# here` -- the guard reddening on a comment DOCUMENTING ITS OWN PROPERTY, which
# is exactly the reasoning that made me exempt whole-line `///` one commit
# earlier. A guard that fires on its own documentation gets deleted within a
# week, and the direction of the error does not change that.
#
# NOTE THE AXIS: the previous two repairs both moved the NEEDLE (right
# boundary, then left). This one moves the STRIPPER. Six mutation arms varied
# the needle and none of them could have found this, because they all fed the
# stripper the same shape of input.
#
# Exit codes
#   0  shape holds
#   1  shape broken (a count moved)
#   2  instrument fault (missing path, or the positive control is dead)
set -u

cd "$(dirname "$0")/.." || { echo "INSTRUMENT: cannot reach repo root"; exit 2; }

TESTS_DIR="Tests/ZeusTests"
PROD="Sources/ZeusApp/HTTPTransport.swift"

for p in "$TESTS_DIR" "$PROD"; do
  [ -e "$p" ] || { echo "INSTRUMENT: missing path: $p"; exit 2; }
done

# Strip whole-line // and /// comments, then count a needle across files.
# code_hits — count CODE-LINE matches of $1 across files $2..
#
# LOAD-BEARING SHAPE, do not simplify (2026-09-02, Zeus100's isolation).
# `grep -c` exits 1 on NO MATCH, and the clean tree IS the no-match world on
# the test arm — a zero here is the SUCCESS case, not a failure. This body used
# to sit behind a bare `c=$(sed … | grep -c …)`, which survived only because
# every call site wraps it in `VAR=$(code_hits …)`: an outer command
# substitution does not inherit errexit in bash < 4.4 / without
# `shopt -s inherit_errexit`. Zeus100 proved the immunity is POSITIONAL, not
# structural — the identical statement written at top level dies under
# `set -euo pipefail`, and inlining this body at its two call sites (the edit a
# reader makes to shorten the script) would make the hardening lethal on a
# CLEAN tree.
#
# So the rc is no longer LUCK. Streams are separated, the producer's rc is
# asserted ALONE, and grep's rc is classified THREE ways rather than tested for
# zero: 0 = hits, 1 = honest zero, anything else = INSTRUMENT FAULT (rc 2).
# A dead producer can therefore never present as a clean count. Verified under
# bash 3.2.57 and 5.3.15, with and without `shopt -s inherit_errexit`, both
# nested and at top level.
code_hits() { # $1=needle  $2..=files -> prints count; returns 2 on instrument fault
  needle="$1"; shift
  n=0
  for f in "$@"; do
    # BLOCK-COMMENT GATE. `/* */` spans lines and nests; a line-oriented
    # stripper cannot honour it, so this NAMES the bound and refuses rather
    # than half-parsing. Corpus has zero block-comment openers today
    # (measured). If one appears this exits 2 -- INSTRUMENT, not BROKEN --
    # because the fault is in the stripper's reach, not the tree's network
    # shape, and the two must not share an exit code.
    bcrc=0
    bc=$(grep -cE '/\*' "$f") || bcrc=$?
    case "$bcrc" in
      0|1) : ;;
      *) echo "INSTRUMENT: grep rc=$bcrc scanning for block comments in $f" >&2; return 2 ;;
    esac
    if [ "$bc" -ne 0 ]; then
      echo "INSTRUMENT: $f contains $bc block-comment opener(s). This stripper is" >&2
      echo "            line-oriented and does not parse /* */; it refuses rather" >&2
      echo "            than half-parse. Remove the block comment, or give the" >&2
      echo "            stripper a real lexer." >&2
      return 2
    fi
    tmp="${TMPDIR:-/tmp}/ch.$$.$n"
    # Comment stripping, TWO forms stripped and ONE refused (2026-09-02,
    # Zeus100's M-TRAILING / M-BLOCK arms).
    #   1. whole-line //  and ///            -> dropped (was the only form)
    #   2. TRAILING // on a line with no `"` -> dropped
    #   3. /* */ block                       -> REFUSED at the gate above, not
    #                                           parsed. A stripper that
    #                                           half-parses a grammar lies in a
    #                                           direction nobody audits.
    # The `no "` condition is the exact bound and it is LOAD-BEARING: with a
    # quote on the line the `//` may sit inside a string literal (a URL), and
    # dropping the tail would eat real code -- a FALSE CLEAR. Deleting the
    # `/"/!` turns `let u = "http://x/URLSession"` from RED to GREEN; that
    # mutation was run.
    sed -e 's;^[[:space:]]*//.*$;;' -e '/"/!s;//.*$;;' "$f" > "$tmp"; sedrc=$?
    if [ "$sedrc" -ne 0 ]; then
      echo "INSTRUMENT: sed rc=$sedrc on $f" >&2; rm -f "$tmp"; return 2
    fi
    greprc=0
    c=$(grep -cE "(^|[^A-Za-z0-9_])${needle}([^A-Za-z0-9_]|$)" "$tmp") || greprc=$?
    rm -f "$tmp"
    case "$greprc" in
      0|1) : ;;                                  # hits / honest zero
      *) echo "INSTRUMENT: grep rc=$greprc on $f" >&2; return 2 ;;
    esac
    n=$(( n + c ))
  done
  printf '%s' "$n"
}

# bash 3.2 compatible enumeration — no mapfile.
TEST_FILES=()
while read -r f; do
  TEST_FILES+=("$f")
done < <(find "$TESTS_DIR" -name '*.swift' -type f | sort)

[ "${#TEST_FILES[@]}" -ge 1 ] || { echo "INSTRUMENT: zero test files found under $TESTS_DIR"; exit 2; }

# POSITIVE CONTROL — a needle known present in every XCTest file. If this reads
# zero the stripper ate the input and every zero below is meaningless rather
# than clean.
# Each call checks code_hits' OWN rc before reading its value. An instrument
# fault inside the helper (rc 2) otherwise arrives here as an EMPTY string, and
# an empty string fails the POS-ctl integer test — exiting 2 by the wrong route,
# with a message blaming the corpus for a fault in the stripper.
chrc=0; POS=$(code_hits 'XCTestCase' "${TEST_FILES[@]}") || chrc=$?
[ "$chrc" -eq 0 ] || { echo "INSTRUMENT: code_hits faulted (rc=$chrc) on the positive control"; exit 2; }
[ "$POS" -ge 1 ] || { echo "INSTRUMENT: positive control XCTestCase = 0 across ${#TEST_FILES[@]} files"; exit 2; }

chrc=0; TEST_URLSESSION=$(code_hits 'URLSession' "${TEST_FILES[@]}") || chrc=$?
[ "$chrc" -eq 0 ] || { echo "INSTRUMENT: code_hits faulted (rc=$chrc) on the test arm"; exit 2; }
chrc=0; PROD_URLSESSION=$(code_hits 'URLSession' "$PROD") || chrc=$?
[ "$chrc" -eq 0 ] || { echo "INSTRUMENT: code_hits faulted (rc=$chrc) on the prod arm"; exit 2; }

echo "files=${#TEST_FILES[@]}  POSctl(XCTestCase)=$POS"
echo "tests URLSession (code lines) = $TEST_URLSESSION   expected 0"
echo "prod  URLSession (code lines) = $PROD_URLSESSION   expected >= 1"

rc=0
if [ "$TEST_URLSESSION" -ne 0 ]; then
  echo "BROKEN: a test source references URLSession on a code line. The suite is"
  echo "        no longer pure — a green run now depends on a network."
  grep -n 'URLSession' "${TEST_FILES[@]}" | sed 's/^/  /'
  rc=1
fi
if [ "$PROD_URLSESSION" -lt 1 ]; then
  echo "BROKEN: HTTPTransport.swift no longer references URLSession — the client"
  echo "        moved, and this guard is now measuring the wrong file."
  rc=1
fi

[ "$rc" -eq 0 ] && echo "OK: network shape holds"
exit "$rc"
