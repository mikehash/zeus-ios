//! Bindgen entry point. `cargo run --bin uniffi-bindgen -- generate --library <staticlib>`
//! is how the Swift bindings in `Sources/ZeusCoreBridge/` are produced; the exact
//! command lives in `scripts/build-xcframework.sh` so it is executable, not remembered.
fn main() {
    uniffi::uniffi_bindgen_main()
}
