# Zeus — iOS

100% Swift. SwiftUI, no UIKit, no bridging header, no carried-over scaffolding.

## Build

**`Zeus.xcodeproj` is not tracked. Generate it before opening Xcode:**

```sh
brew install xcodegen   # once
xcodegen generate       # writes Zeus.xcodeproj from project.yml
open Zeus.xcodeproj
```

`project.yml` is the single source of truth for the project structure. The
`.xcodeproj` is a generated artifact — tracking it beside its generator would be
two truths for one fact, and the generated one is always the one that drifts.
Re-run `xcodegen generate` after any change to `project.yml` or after adding a
source file outside `Sources/ZeusApp`.

## Gate

```sh
xcodebuild -scheme Zeus \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build
```

`BUILD SUCCEEDED` alone is not a verdict — an empty target prints it too.

### The membership check (use this one)

```sh
bash scripts/check_membership.sh      # rc 0 pass · 2 VOID · 3 DRIFT
```

Asks the *driver input list* — what the compiler was handed — not the build
log, which is what it decided to redo. Two faults it exists to avoid, both
measured on this repo:

- **Do not glob DerivedData and `head -1`.** That selected a 6.5h-stale hash
  whose list held 8 inputs with the file under test absent — a false zero.
  `xcodebuild -showBuildSettings` emits `OBJROOT` for the invocation you are
  about to run: a coordinate written by the build system, not a claim about
  the filesystem written by the reader.
- **Do not compare against `git ls-files`.** The file list enumerates the
  WORKING TREE; the index is a different set, and they disagree exactly when
  something is uncommitted — i.e. every time you add a file. A guard that
  false-reds on normal work trains you to ignore it. Use
  `--cached --others --exclude-standard`.

A positive control cannot catch a stale list: a stale artefact contains every
*old* file, so any control drawn from pre-existing code is alive in it by
construction. Membership is a property of an element; staleness is a property
of the set. Only cardinality or recency sees it — hence the count comparison,
and hence mtime is printed as a corroborator and never as the verdict.

### Two checks that look right and are not

- `grep -c SwiftDriver` — a **count**, and a count cannot say *which* file. The
  number moves with recompilation, not with membership. It was in this README
  and it was wrong.
- `grep -oE '[A-Za-z]+\.swift'` over the build log — a **work log**. On an
  incremental build Xcode skips unchanged files, so this returns a plausible
  subset. It also returns names that are not source files at all: a cold build
  here emits `Zeus.swift` (an object-file path), `simulator.swift` (from
  `x86_64-apple-ios-simulator.swift`) and `tools.swift` (from
  `com.apple.xcode.tools.swift`) — three hits, zero files. A substring match on
  a log is not a file set.

Current: 8 files in the list, 8 on disk, sets identical, `zzznope` control 0.
(`pbxproj` stores **basenames** — grep for `Foo.swift`, not `Sources/ZeusApp/Foo.swift`,
or every file reports MISSING.)

## Layout

```
project.yml               XcodeGen manifest — source of truth
Sources/ZeusApp/          app sources
  ZeusApp.swift           @main entry
  Theme.swift             design tokens (colors, type ramp, spacing)
  AgentState.swift        agent-state enum + Badge
  DeviceOrb.swift         the orb renderer — 5 layers, ported from the JSX prototype
  OrbBench.swift          headless frame-cost harness (CPU geometry + depth sort only)
  RootView.swift          tab shell, toast host
  SessionView.swift       SESSION tab — transcript, composer
  NodesView.swift         NODES tab — fleet, Row/Slider helpers
  Info.plist
```

## Provenance

Every view is transcribed from the landed prototype at

```
817b19d3d:docs/prototypes/mobile/zeus/ZeusApp.jsx   (925 lines)
```

which is the **canonical** copy in `~/Zeus`, not the purge-candidate tree.
Transcription, not derivation: if the prototype moves, nothing here follows and
nothing goes red. Line citations in the sources are against that ref.

Known gaps are recorded **in the files**, at the site, not here — the three
type families are not vendored, `send()` has no transport, `nodeOnline` and the
`remote` ternary have no producer, and every icon is a hand-picked SF Symbol
substitute. Each is green and wrong, which is why it is written where the
reader already is.

## Requirements

- iOS 17.0 deployment target
- Xcode with an iOS Simulator SDK
- XcodeGen
