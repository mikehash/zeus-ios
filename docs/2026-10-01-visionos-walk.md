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
