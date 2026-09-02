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
# Comment stripping is deliberately conservative: only whole-line // and ///
# forms are dropped. A trailing comment after code still counts, which can only
# produce a FALSE POSITIVE (a refusal), never a false clear.
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
code_hits() { # $1=needle  $2..=files
  needle="$1"; shift
  n=0
  for f in "$@"; do
    c=$(sed -e 's;^[[:space:]]*//.*$;;' "$f" | grep -cE "(^|[^A-Za-z0-9_])${needle}([^A-Za-z0-9_]|$)")
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
POS=$(code_hits 'XCTestCase' "${TEST_FILES[@]}")
[ "$POS" -ge 1 ] || { echo "INSTRUMENT: positive control XCTestCase = 0 across ${#TEST_FILES[@]} files"; exit 2; }

TEST_URLSESSION=$(code_hits 'URLSession' "${TEST_FILES[@]}")
PROD_URLSESSION=$(code_hits 'URLSession' "$PROD")

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
