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

`BUILD SUCCEEDED` alone is not a verdict — an empty target prints it too. Check
that the compiler actually ran:

```sh
xcodebuild ... build | grep -c SwiftDriver   # must be > 0
```

## Layout

```
project.yml               XcodeGen manifest — source of truth
Sources/ZeusApp/          app sources
  ZeusApp.swift           @main entry
  Theme.swift             design tokens (colors, type ramp, spacing)
  RootView.swift          tab shell
  Info.plist
```

## Requirements

- iOS 17.0 deployment target
- Xcode with an iOS Simulator SDK
- XcodeGen
