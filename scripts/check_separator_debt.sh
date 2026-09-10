#!/bin/bash
# Census of un-migrated `·` interpolation sites, PER FILE.
#
# The separator ruling migrated only the strips read on the 390pt frames.
# The rest are DEBT, and this pins them so a silent drift in either direction
# is visible: migrating without updating fails, and a NEW bare-glyph site fails.
#
# WHY PER FILE AND NOT A SCALAR — this is the whole repair, and it was bought
# with a miss. The old form pinned one number (`EXPECTED=28`). At `9cc5ffa`,
# (h) DELETED `zeus-core 0.9 · this iphone` from `NodesView.swift` and CREATED
# `core \(short) · this iphone` in a brand-new `CoreProvenance.swift` in the
# same commit. One out, one in, total unchanged — and the new literal wrapped
# on the 390pt frame with the dot stranded at the line end, the exact defect
# `Theme.joined` exists to prevent. A SCALAR COUNT CANNOT SEE A RELOCATION.
# The file is the smallest unit that can, so the pin is a per-file manifest.
#
# APERTURE, stated because the numbers are meaningless without it: `Sources`,
# `*.swift`, whole-line comments excluded, `Theme.separator` excluded. A file
# not listed below must have ZERO sites — that is how a new file reddens here
# instead of arriving unmeasured. `CoreProvenance.swift` WAS inside this
# aperture and was counted correctly; the aperture was never the fault.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

# file:count, sorted. A new file with a site is absent here → FAIL.
EXPECTED='Sources/ZeusApp/Approvals.swift:1
Sources/ZeusApp/Commissioning.swift:1
Sources/ZeusApp/GatewayEditor.swift:6
Sources/ZeusApp/HomeView.swift:1
Sources/ZeusApp/LinkMonitor.swift:6
Sources/ZeusApp/NodesView.swift:1
Sources/ZeusApp/OrbBench.swift:1
Sources/ZeusApp/PushRegistrar.swift:2
Sources/ZeusApp/RootView.swift:1
Sources/ZeusApp/Route.swift:4
Sources/ZeusApp/Theme.swift:1'

hits=$(grep -rn '·' Sources --include='*.swift' 2>/dev/null \
       | grep -v '^[^:]*:[0-9]*: *//' \
       | grep -v 'Theme.separator')

# POS control in the SAME invocation: a needle that finds nothing and a reader
# that is broken produce the same zero, and this reader walks a tree by glob.
pos=$(grep -rc 'Theme' Sources --include='*.swift' 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$pos" -lt 1 ]; then echo "VOID: reader dead (Theme POS = $pos)"; exit 2; fi

actual=$(printf '%s\n' "$hits" | grep -c . | tr -d ' ')
manifest=$(printf '%s\n' "$hits" | cut -d: -f1 | sort | uniq -c \
           | awk '{print $2 ":" $1}' | sort)
want=$(printf '%s\n' "$EXPECTED" | sort)

echo "separator debt: $actual sites across $(printf '%s\n' "$manifest" | grep -c .) files · POS Theme = $pos"

if [ "$manifest" != "$want" ]; then
  echo "FAIL: separator debt moved — per-file manifest differs"
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$manifest") | sed 's/^/  /'
  exit 1
fi
echo "OK: every un-migrated site is a known one"
