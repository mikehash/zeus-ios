# visionOS app — walk + running notes (2026-10-01, zeus106)

Base: zeus-ios main `dcdb42f` (5/5 core pins `d5a539bd`), branch `feat/visionos-app`.

## Gate plan (agreed with Zeus100)
1. build-infra: `build-xcframework.sh` + `project.yml` gain visionOS slices → FF + diff.
2. app compiles for visionOS sim → compile receipt.
3. tests on visionOS sim → test count.
Any commit touching rust bridge/core: Zeus100 rebuilds it independently.

## Substrate
- SDKs: XROS 26.5, XRSimulator 26.5. Rust 1.95.0 has `aarch64-apple-visionos{,-sim}`.
- `build-xcframework.sh`: iOS device + sim only, `IPHONEOS_DEPLOYMENT_TARGET=17.0`.
- `project.yml`: single iOS target.
- iPhone-API surface in Sources: AVAudioSession 11, Speech 10, PhotosPicker 11,
  UserNotifications 6, push registration 5, fileImporter 1, AudioServices chime 1.
  Availability to be decided by compiling for the visionOS sim, not docs.
  Fallback rule: compile-gated off → disabled + shown UNAVAILABLE, never hidden.

## Log
- 21:57 +04 — first full bridge staticlib build for visionOS sim started
  (`XROS_DEPLOYMENT_TARGET=1.0 cargo +1.95.0 build --lib --release
  --target aarch64-apple-visionos-sim`, tmux `vos-bridge`, log
  `/tmp/vos-bridge-sim.log`, ends `EXIT=N`). Prior visionOS evidence covered
  `cargo check -p zeus-agent` only — this is the first link-artifact build.
- 22:1x +04 — step 1 edits (uncommitted until the script runs green end-to-end):
  `build-xcframework.sh` gains `xros`/`xrsimulator` SDK probes, an
  `XROS_DEPLOYMENT_TARGET` read from `project.yml` (`deploymentTarget.visionOS`,
  same no-drift rule as `IOS_MIN`), two cargo slice builds, two more
  `-library` flags, and manifest lines (sdk/min/sha per slice).
  `project.yml` gains `visionOS: "2.0"` under `deploymentTarget` only — the
  app target stays iOS-only until gate 2 (destination + `TARGETED_DEVICE_FAMILY`
  change lands with the compile receipt, not before it). `bash -n` rc=0.
  No rust source touched.

## Stage-2 pre-walk (22:07, while stage-1 xcframework runs)
Files touching candidate iPhone-only APIs (AVAudioSession|SFSpeech|PhotosPicker|UNUserNotification|registerForRemoteNotifications|fileImporter|AudioServicesPlaySystemSound|UIApplication), per-file hit counts:
Voice 15, PushSystem 10, SessionView 9, SpeechAudio 8, PushRegistrar 6, AttachDoor 3, Narrator 2, RootView 2, DeviceOrb 1, ZeusApp 1.
Verdict comes from compiling for the xrsimulator destination, not from this list.

## Gate 1 receipt — xcframework 4 slices (2026-10-01 23:22 +04)

- Run: `scripts/build-xcframework.sh` in tmux `vos-xcf`, log `/tmp/vos-xcf.log`, `EXIT=0` (log line 603).
- Built at crate-sha `1321913f` = `cbd941c` + docs-only commit (`git diff --stat cbd941c 1321913` touches only `docs/`), so the result holds for `cbd941c`'s script/project.
- Core pin `d5a539bd78498954e1685989ce1c508b96d6a40e`; Xcode 26.5 (17F42); rustc 1.95.0; ios-min 17.0, xros-min 2.0.
- `plutil` on `Frameworks/ZeusCore.xcframework/Info.plist` (checked independently, not from the script summary): `AvailableLibraries` = 4 —
  `ios-arm64` (ios/device), `ios-arm64-simulator` (ios/simulator), `xros-arm64` (xros/device), `xros-arm64-simulator` (xros/simulator).
- Bindings: `git diff` on `Sources/ZeusCoreFFI` is empty — regen is byte-identical to `dcdb42f`, so visionOS adds no FFI surface.
- The xcframework is gitignored (`.gitignore:19`), so it's a local artifact; the receipt is this paragraph.
- Next: gate 2 — visionOS destination in project.yml + xrsimulator app compile; verdicts for the stage-2 census come from that compile.

## Gate 2 — visionOS destination + xrsimulator app compile (2026-10-01 23:3x +04, branch feat/visionos-gate2 off df26d95)
- project.yml: Zeus target `platform: auto` + `supportedDestinations: [iOS, visionOS]`; `TARGETED_DEVICE_FAMILY "1,7"` (iPad still out); xcodegen 2.46.0 → pbxproj `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator xros xrsimulator"`.
- First compile, `generic/platform=visionOS Simulator`: EXIT=65. The single error is at Ld for **x86_64**, where the xcframework has arm64-only sim slices. Swift compiled clean, so this is not an API failure.
- Re-run with `ARCHS=arm64`: **BUILD SUCCEEDED, EXIT=0, 0 `error:` lines** (/tmp/vos-g2b.log). The app's Swift, including every file in the stage-2 iPhone-only census, compiles for xrsimulator as-is, so the census has no compile-level verdicts. Unavailable-at-runtime behaviour (e.g. haptics or photos on visionOS) is a separate question; it is unanswered and needs a sim run.
- Structural fix: `EXCLUDED_ARCHS[sdk=xrsimulator*|iphonesimulator*] = x86_64` in project.yml. The visionOS rebuild without the ARCHS override is the confirming leg.
- Confirming legs at 20caeeb, with no command-line ARCHS override:
  - visionOS Simulator: BUILD SUCCEEDED, EXIT=0, 0 errors (/tmp/vos-g2c.log).
  - iOS Simulator regression leg: BUILD SUCCEEDED, EXIT=0, 0 errors (/tmp/ios-g2d.log). The first attempt (/tmp/ios-g2c.log) ended `BUILD INTERRUPTED` because its tmux server died; it is VOID, not a failure.
- Not yet measured: the visionOS device (xros) app build, and `xcodebuild test`.
