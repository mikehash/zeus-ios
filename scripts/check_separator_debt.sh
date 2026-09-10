#!/bin/bash
# Census of un-migrated `·` interpolation sites, pinned as a SET.
#
# WHY A SET OF SITES AND NOT A COUNT — this is the whole repair, and both
# weaker forms were tried and both missed.
#
#   1. SCALAR (`EXPECTED=28`). At `9cc5ffa`, (h) DELETED
#      `zeus-core 0.9 · this iphone` from `NodesView.swift` and CREATED
#      `core \(short) · this iphone` in a brand-new `CoreProvenance.swift`
#      in the same commit. One out, one in, total unchanged — and the new
#      literal wrapped on the 390pt frame with the dot stranded at the line
#      end, the exact defect `Theme.joined` exists to prevent.
#      A COUNT CANNOT SEE A SWAP.
#
#   2. PER-FILE COUNTS. Better — a new FILE reddens — but a swap WITHIN one
#      file is still invisible: retire one site and add another in the same
#      file and the file's number does not move. Same cardinality blindness,
#      one scope smaller.
#
# So the pin is the set of surviving sites: file + the line TEXT, whitespace
# collapsed, LINE NUMBER DELIBERATELY EXCLUDED. The number is not a property
# of the site — inserting an unrelated line above it would red every site
# below and train the reader to re-bless the manifest without reading it,
# which is how a pin becomes a rubber stamp. The text is the site.
#
# A new site reds even when an old one retires in the same commit. A
# retirement reds too, and is cleared by DELETING its line here — lowering
# the expected set is explicit, never implicit.
#
# APERTURE, stated because the numbers are meaningless without it: `Sources`,
# `*.swift`, whole-line comments excluded, `Theme.separator` call sites
# excluded (the definition in `Theme.swift` is itself pinned below).
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

EXPECTED='Sources/ZeusApp/Approvals.swift|reason: "\(endpoint.url.host ?? "gateway") · \(error.localizedDescription)")
Sources/ZeusApp/Commissioning.swift|Text("OPERATOR VERIFIED · MIGUEL")
Sources/ZeusApp/GatewayEditor.swift|Text("PREFLIGHT · GET /v1/status")
Sources/ZeusApp/GatewayEditor.swift|Text(tokens.hasToken(host: Self.hostKey(for: config)) ? "PRESENT · KEYCHAIN" : "NOT SET")
Sources/ZeusApp/GatewayEditor.swift|case (true, .cleared): return "TOKEN SAVED · URL CLEARED — LIVE NOW"
Sources/ZeusApp/GatewayEditor.swift|case (true, .wrote): return "TOKEN SAVED · URL SAVED — LIVE NOW"
Sources/ZeusApp/GatewayEditor.swift|return savedToken ? "TOKEN SAVED · NO COMMISSION — URL NOT STORED"
Sources/ZeusApp/GatewayEditor.swift|subtitle: "source · \(resolution.source.rawValue)") {
Sources/ZeusApp/HomeView.swift|Text("·")
Sources/ZeusApp/LinkMonitor.swift|return "LINKED · \(host.uppercased()) · \(ms)MS"
Sources/ZeusApp/LinkMonitor.swift|return "LOCAL · ON THIS PHONE"
Sources/ZeusApp/LinkMonitor.swift|return "NO GATEWAY · SET ZEUS_GATEWAY_URL"
Sources/ZeusApp/LinkMonitor.swift|return "REMOTE · \(host.uppercased()) · \(reason.uppercased())"
Sources/ZeusApp/LinkMonitor.swift|return "\(host) · /health 200 · \(ms)ms"
Sources/ZeusApp/LinkMonitor.swift|return "\(host) · \(reason)"
Sources/ZeusApp/NodesView.swift|Text("ZEUS · NOVAXAI")
Sources/ZeusApp/OrbBench.swift|String(format: "%4d pts · %6.3f ms/frame · glow candidates %4d · %@",
Sources/ZeusApp/PushRegistrar.swift|return "allowed · no device token yet"
Sources/ZeusApp/PushRegistrar.swift|return "token ·\(suffix)"
Sources/ZeusApp/RootView.swift|return "\(base) · \(source.rawValue)"
Sources/ZeusApp/Route.swift|case lanOnly = "LAN BY DEFAULT · NO EGRESS"
Sources/ZeusApp/Route.swift|return "ROUTE PREFERRED — \(route.name) · THIS DEVICE"
Sources/ZeusApp/Route.swift|return .unavailable(reason: "\(endpoint.url.host ?? "gateway") · \(error.localizedDescription)")
Sources/ZeusApp/Route.swift|return head + " · ACTIVE \(model)"
Sources/ZeusApp/Theme.swift|static let separator = "\u{00A0}·\u{00A0}"'

hits=$(grep -rn '·' Sources --include='*.swift' 2>/dev/null \
       | grep -v '^[^:]*:[0-9]*: *//' \
       | grep -v 'Theme.separator' \
       | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1|/' \
       | tr -s ' ' \
       | sed -E 's/[[:space:]]+$//' \
       | sort)

# POS control in the SAME invocation: a needle that finds nothing and a
# reader that is dead produce the same zero, and this reader walks a tree
# by glob. If `Theme` itself is unfindable the census is void, not clean.
pos=$(grep -rc 'Theme' Sources --include='*.swift' 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$pos" -lt 1 ]; then echo "VOID: reader dead (Theme POS = $pos)"; exit 2; fi

want=$(printf '%s\n' "$EXPECTED" | sort)
actual=$(printf '%s\n' "$hits" | grep -c .)

# A set silently absorbs duplicates, so assert the two texts really are
# distinct sites before comparing as sets — otherwise two identical lines
# in one file collapse to one and the pin is blind again.
uniq_n=$(printf '%s\n' "$hits" | sort -u | grep -c .)
if [ "$actual" -ne "$uniq_n" ]; then
  echo "VOID: $actual sites collapse to $uniq_n distinct texts — set pin cannot see the difference"
  printf '%s\n' "$hits" | sort | uniq -d | sed 's/^/  dup: /'
  exit 2
fi

echo "separator debt: $actual sites across $(printf '%s\n' "$hits" | cut -d'|' -f1 | sort -u | grep -c .) files · POS Theme = $pos"

if [ "$want" != "$hits" ]; then
  echo "FAIL: separator debt moved — pinned site set differs"
  echo "  (< = pinned but gone: delete the line here. > = NEW site: migrate it or pin it.)"
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$hits") | sed 's/^/  /'
  exit 1
fi
echo "OK: every un-migrated site is a known one"
