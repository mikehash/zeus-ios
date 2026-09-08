#!/bin/bash
# Census of un-migrated `·` interpolation sites.
#
# The separator ruling migrated only the strips read on the 390pt frames.
# The rest are DEBT, and this pins the number so a silent drift in either
# direction is visible: migrating more without updating the count fails,
# and adding a new bare-glyph site fails.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
EXPECTED=28

out=$(grep -rn '·' Sources --include='*.swift' 2>/dev/null \
      | grep -v '^[^:]*:[0-9]*: *//' \
      | grep -v 'Theme.separator')
rc=$?
# POS control in the SAME invocation: a needle that finds nothing and a
# reader that is broken produce the same zero.
pos=$(grep -rc 'Theme' Sources --include='*.swift' 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$pos" -lt 1 ]; then echo "VOID: reader dead (Theme POS = $pos)"; exit 2; fi

n=$(printf '%s' "$out" | grep -c . )
echo "un-migrated separator sites: $n (expected $EXPECTED) · POS Theme = $pos"
[ "$n" -eq "$EXPECTED" ] || { echo "FAIL: separator debt moved"; printf '%s\n' "$out"; exit 1; }
