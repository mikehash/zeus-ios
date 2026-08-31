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

Ask the *driver input list*, not the build log. The list is what the compiler
was handed; the log is what it decided to redo.

```sh
FL=$(find ~/Library/Developer/Xcode/DerivedData/Zeus-*/Build/Intermediates.noindex \
       -name 'Zeus.SwiftFileList' -path '*arm64*' | head -1)
diff <(tr ' ' '\n' < "$FL" | sed 's|.*/||' | grep '\.swift$' | sort) \
     <(find Sources -name '*.swift' -exec basename {} \; | sort)   # must be empty
```

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

Current: 6 files in the list, 6 on disk, sets identical, `zzznope` control 0.

## Layout

```
project.yml               XcodeGen manifest — source of truth
Sources/ZeusApp/          app sources
  ZeusApp.swift           @main entry
  Theme.swift             design tokens (colors, type ramp, spacing)
  AgentState.swift        agent-state enum + Badge
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
