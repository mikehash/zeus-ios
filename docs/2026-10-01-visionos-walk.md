# visionOS — substrate walk (read-only, no code)

Base: zeus-ios origin/main at walk time; core pin mikehash/Zeus @ 8e19318c; crate toolchain 1.95.0 (rust/zeus-core-bridge/rust-toolchain.toml).

## Finding: the Rust core does not build for visionOS today

- Toolchain: 1.95.0 ships `aarch64-apple-visionos` + `-sim` (Tier 3 std, installed via rustup). Xcode SDKs xros / xrsimulator 26.5 present.
- `cargo build --lib --release --target aarch64-apple-visionos-sim` → rc=101; same on `aarch64-apple-visionos`.
- Error: `wasmtime-fiber 28.0.1` — `<inline asm>: unknown directive .hidden`. `wasmtime-asm-macros` picks Mach-O syntax only under `target_os = "macos"`; visionOS falls through to the ELF branch.
- Why wasmtime is linked at all: zeus-skills gates wasmtime/wasmtime-wasi under `cfg(not(target_os = "ios"))`. visionOS reports `target_os = "visionos"`, so the iOS exclusion does not fire.
  - `cargo tree -e normal`: aarch64-apple-ios fiber=0, visionos-sim fiber=1 (control: tokio present on both, 37/38).
- Census of the iOS gates in the pinned core: 29 sites of `target_os = "ios"` across zeus-agent (3), zeus-channels (1 toml + 19 rs), zeus-skills (1 toml... 2 lines + 4 rs). `visionos` appears 0 times. Same counts on Zeus origin/main (29 / 0).

## Consequence

Every gate that today means "the phone build" means "iOS only". A visionOS build gets the desktop dependency set (wasmtime, and whatever zeus-channels excludes). Fixing the first compile error would only expose the next one.

## Options

1. **Core change (lean):** in mikehash/Zeus, widen the 29 gates from `target_os = "ios"` to a mobile-apple predicate (`any(target_os = "ios", target_os = "visionos")`), then re-pin the bridge. Touches main Zeus → needs coordinator routing; bridge pin moves.
2. **Bridge-only:** not possible — the gates are in dependencies' Cargo.toml target tables; the bridge can't remove a dep a dependency declares.
3. **Thin client:** visionOS app ships without the embedded core, gateway-only (GatewayCapabilities/HTTPTransport already exist). No Rust change; loses on-device mode.

Not done: no app target, no xcframework slice, no Swift change.
