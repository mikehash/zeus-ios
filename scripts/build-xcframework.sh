#!/bin/bash
set -euo pipefail

# build-xcframework.sh — package the Rust bridge as ZeusCore.xcframework.
#
# Shape borrowed from apps/ZeusDesktop/scripts/build-xcframework.sh in
# mikehash/Zeus, with three deliberate divergences, each because the target
# platform differs:
#
#   1. Desktop lipo's two macOS arches into ONE universal slice. iOS cannot:
#      device (aarch64-apple-ios) and simulator (aarch64-apple-ios-sim) are
#      different platforms, not different arches, and -create-xcframework
#      requires them as SEPARATE -library arguments. lipo'ing them produces an
#      archive that xcodebuild rejects at embed time. Hence two slices.
#   2. Desktop generates bindings from a .dylib. This crate is staticlib-only
#      (a cdylib would double link time for nothing), so bindgen reads the .a —
#      measured working with uniffi 0.28.
#   3. Every input that can differ between boxes is printed into a manifest
#      beside the artifact. The device and simulator slices of an xcframework
#      may be produced on different machines; without the manifest, "which
#      compiler, which SDK" is an unrecoverable per-box fact after the fact.

CRATE_DIR="$(cd "$(dirname "$0")/../rust/zeus-core-bridge" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Frameworks"
LIB_NAME="zeus_core_bridge"
FRAMEWORK="ZeusCore.xcframework"

cd "$CRATE_DIR"

# ---------------------------------------------------------------------------
# 0. Provenance. Collected BEFORE the build so the manifest describes the
#    toolchain that actually produced the slices, and printed to the terminal
#    so a human watching sees it too.
#
#    rustc is read from inside $CRATE_DIR so rust-toolchain.toml governs —
#    reading it from the repo root reports the box default (measured: 1.97.1
#    at the root vs 1.95.0 here) and would silently record the wrong compiler.
# ---------------------------------------------------------------------------
RUSTC_V="$(rustc --version)"
CARGO_V="$(cargo --version)"
XCODE_V="$(xcodebuild -version | tr '\n' ' ')"

SDK_IOS=""; SDK_SIM=""
sdk_or_die() {
    local sdk="$1" path rc=0
    path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/tmp/xcrun.$$.err)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$path" ]; then
        echo "FATAL: no $sdk SDK on this box (xcrun rc=$rc)" >&2
        cat /tmp/xcrun.$$.err >&2
        rm -f /tmp/xcrun.$$.err
        # A Command-Line-Tools-only box prints a BLANK LINE here, not an error:
        # a stdout-only probe reads that as a formatting glitch rather than a
        # missing toolchain. Hence rc and emptiness are both checked.
        exit 1
    fi
    rm -f /tmp/xcrun.$$.err
    printf '%s' "$path"
}
SDK_IOS="$(sdk_or_die iphoneos)"
SDK_SIM="$(sdk_or_die iphonesimulator)"

echo "=== toolchain ==="
echo "  rustc:   $RUSTC_V"
echo "  cargo:   $CARGO_V"
echo "  xcode:   $XCODE_V"
echo "  sdk ios: $SDK_IOS"
echo "  sdk sim: $SDK_SIM"

# ---------------------------------------------------------------------------
# 1. Both slices, release.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 0b. Deployment target. NOT cosmetic — measured.
#
# rustc defaults *_DEPLOYMENT_TARGET to the SDK version it finds (26.5 on this
# box). The app declares iOS 17.0 in project.yml. Linking the unpinned slices
# produced ~400 lines of
#   ld: warning: object file ... was built for newer 'iOS-simulator' version
#       (26.5) than being linked (17.0)
# and the build still exited 0 — a warning-only failure mode that says the
# archive's minimum OS is 9 majors above the app's. It reproduces only on a
# CLEAN link: the second xcodebuild run printed ZERO warnings from the same
# unfixed archive, because the objects were already staged. A green re-run here
# is cache, not repair.
#
# Pinned to the same 17.0 the app declares. Read from project.yml so the two
# cannot drift: a hardcoded 17.0 here would go stale the day the app raises it.
IOS_MIN="$(grep -A2 'deploymentTarget:' "$REPO_ROOT/project.yml" | grep -oE 'iOS: *"[0-9.]+"' | grep -oE '[0-9.]+' | head -1)"
[ -n "$IOS_MIN" ] || { echo "FATAL: could not read iOS deploymentTarget from project.yml" >&2; exit 1; }
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN"
echo "  ios-min: $IOS_MIN (from project.yml)"

echo "=== building device slice (aarch64-apple-ios) ==="
cargo build --lib --release --target aarch64-apple-ios

echo "=== building simulator slice (aarch64-apple-ios-sim) ==="
cargo build --lib --release --target aarch64-apple-ios-sim

DEVICE_LIB="$CRATE_DIR/target/aarch64-apple-ios/release/lib${LIB_NAME}.a"
SIM_LIB="$CRATE_DIR/target/aarch64-apple-ios-sim/release/lib${LIB_NAME}.a"
for lib in "$DEVICE_LIB" "$SIM_LIB"; do
    [ -f "$lib" ] || { echo "FATAL: missing $lib" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 2. Swift bindings, generated from the device archive.
#
#    Checked in under Sources/ZeusCoreFFI/ so the app builds without a Rust
#    toolchain present. The generating command is in the commit body; this
#    script is that command.
# ---------------------------------------------------------------------------
BINDINGS_DIR="$REPO_ROOT/Sources/ZeusCoreFFI"
echo "=== generating swift bindings -> $BINDINGS_DIR ==="
mkdir -p "$BINDINGS_DIR"
cargo run --bin uniffi-bindgen -- generate \
    --library "$DEVICE_LIB" \
    --language swift \
    --out-dir "$BINDINGS_DIR"

# Prepend the provenance header. Done HERE, in the generator, because a header
# added by hand would be destroyed by the next run of the very script it tells
# you to run — a comment that falsifies itself on first use. Regenerating now
# reproduces it.
HDR="$(mktemp)"
cat > "$HDR" <<HEADER
// GENERATED — DO NOT EDIT. Regenerate with scripts/build-xcframework.sh
//
//   \$ ./scripts/build-xcframework.sh
//     -> cargo run --bin uniffi-bindgen -- generate \\
//          --library rust/zeus-core-bridge/target/aarch64-apple-ios/release/lib${LIB_NAME}.a \\
//          --language swift --out-dir Sources/ZeusCoreFFI/
//
// Checked in deliberately: it is compiled as app source, so the app builds on
// any Mac with Xcode and no Rust toolchain. Only LINKING needs the archive,
// which is gitignored and rebuilt by the same script.
//
// crate sha $(cd "$REPO_ROOT" && git rev-parse --short HEAD) · dep pin 2a2168cd · $RUSTC_V
HEADER
cat "$HDR" "$BINDINGS_DIR/${LIB_NAME}.swift" > "$HDR.joined"
mv "$HDR.joined" "$BINDINGS_DIR/${LIB_NAME}.swift"
rm -f "$HDR"

# uniffi emits the .h and .modulemap next to the .swift; the xcframework wants
# the C header, the Swift target wants the .swift, and having both in one
# source dir makes xcodegen compile the header as a source. Split them.
HEADERS="$CRATE_DIR/target/xcframework-headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
mv "$BINDINGS_DIR/${LIB_NAME}FFI.h" "$HEADERS/"
rm -f "$BINDINGS_DIR/${LIB_NAME}FFI.modulemap"
cat > "$HEADERS/module.modulemap" <<MODULEMAP
module ${LIB_NAME}FFI {
    header "${LIB_NAME}FFI.h"
    export *
}
MODULEMAP

# ---------------------------------------------------------------------------
# 3. The xcframework. Two -library flags, one per platform.
# ---------------------------------------------------------------------------
echo "=== creating $FRAMEWORK ==="
mkdir -p "$OUT_DIR"
rm -rf "${OUT_DIR:?}/$FRAMEWORK"
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADERS" \
    -library "$SIM_LIB"    -headers "$HEADERS" \
    -output "$OUT_DIR/$FRAMEWORK"

# ---------------------------------------------------------------------------
# 4. The manifest. Written INTO the artifact, so it travels with the slices
#    rather than living in a log that the next box never sees.
# ---------------------------------------------------------------------------
MANIFEST="$OUT_DIR/$FRAMEWORK/zeus-build-manifest.txt"
{
    echo "built:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host:       $(hostname -s) $(uname -m) $(sw_vers -productVersion)"
    echo "rustc:      $RUSTC_V"
    echo "cargo:      $CARGO_V"
    echo "xcode:      $XCODE_V"
    echo "sdk-ios:    $SDK_IOS"
    echo "sdk-sim:    $SDK_SIM"
    echo "crate-sha:  $(cd "$REPO_ROOT" && git rev-parse HEAD)"
    echo "dep-pin:    $(grep -m1 -oE 'rev = "[0-9a-f]+"' "$CRATE_DIR/Cargo.toml" | head -1)"
    echo "ios-min:    $IOS_MIN"
    echo "slices:     ios-arm64 ios-arm64-simulator"
    echo "device-sha: $(shasum -a 256 "$DEVICE_LIB" | cut -d' ' -f1)"
    echo "sim-sha:    $(shasum -a 256 "$SIM_LIB" | cut -d' ' -f1)"
} > "$MANIFEST"

echo "=== done ==="
cat "$MANIFEST"
echo
echo "xcframework: $OUT_DIR/$FRAMEWORK"
echo "bindings:    $BINDINGS_DIR/${LIB_NAME}.swift"
