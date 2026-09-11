import XCTest
@testable import Zeus

/// D, leg 2 of 2 — THE ONE-ROOT CLAIM.
///
/// Leg 1 lives in Rust (`workspace_root_confines_the_phone_file_tools` in
/// `zeus-core-bridge`): it proves the guard REFUSES an escape and SERVES a
/// path inside, measured through `ZeusCore::init`, which is the bridge's only
/// production caller of `set_workspace_root`.
///
/// That leg proves the guard works around WHATEVER root the core was given.
/// It says nothing about which directory the PHONE hands it — and a guard
/// confining the wrong directory is a guard that is simultaneously perfect and
/// useless. This leg closes that gap: the value fed to `ZeusCore.init` is
/// `EmbeddedCore.workspaceDirectory()`, the same value every other
/// on-device path derives from. One value feeds both, which is why loop and
/// index share a root — not because a getter says so.
///
/// WHY THERE IS NO SWIFT REFUSAL LEG. `ZeusCore` exports ten things and none
/// of them executes a tool by name, so the only route from Swift into
/// `validate_tool_path` is a live model choosing `read_file`. A "simulator
/// escape test" would therefore be a network call inside a unit suite:
/// non-hermetic, red on a box with no key, and a flake wearing a test's name.
/// The refusal is measured in Rust; the wiring is measured here.
///
/// SUBJECT CORRECTION, on the record. The ruled wording — and my own walk —
/// said `EmbeddedTransport.workspaceDirectory()`. The function is a static on
/// `EmbeddedCore` (`EmbeddedTransport.swift:287`), a SECOND type in the same
/// FILE. The file name walked into the type name, exactly as `agent_loop.rs`
/// walked into a nonexistent `AgentLoop` earlier on this branch. The compiler
/// refused it (`has no member`, rc=65) — a `file:LINE` citation proves a
/// definition, never the type that owns it.
final class WorkspaceRootTests: XCTestCase {

    private func transportSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ZeusApp/EmbeddedTransport.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code lines only — this file and `EmbeddedTransport` both DISCUSS the
    /// call in prose, and a whole-file needle would be satisfied by the
    /// commentary explaining the very wiring it is meant to detect.
    private func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("///") && !t.hasPrefix("*")
            }
    }

    /// Control for the stripper: a needle that exists ONLY in a doc comment
    /// must be absent from the filtered set. Without this, a stripper that
    /// silently returned every line would make the census below vacuous while
    /// looking stricter than it is.
    func testTheStripperActuallyStrips() throws {
        let code = codeLines(try transportSource()).joined(separator: "\n")
        XCTAssertFalse(
            code.contains("the system may evict Caches"),
            "prose from a doc comment survived the stripper — every census below is vacuous"
        )
        XCTAssertTrue(
            code.contains("static func workspaceDirectory"),
            "POS: the declaration is on a code line and must survive"
        )
    }

    /// The core is initialised with the workspace directory, and with nothing
    /// else.
    ///
    /// Both arms matter. The first says the wiring exists; the second says
    /// there is exactly ONE construction of the core, because a second
    /// `ZeusCore.init` elsewhere — on a temp dir, a Documents path, a bundle
    /// resource — would set the process-global root to whichever ran last and
    /// silently move the guard off the directory the app actually uses.
    func testTheCoreIsRootedAtTheWorkspaceDirectory() throws {
        let code = codeLines(try transportSource())

        let inits = code.filter { $0.contains("ZeusCore.") && $0.contains("init") }
        XCTAssertEqual(inits.count, 1, "exactly one core construction, got: \(inits)")

        let wired = inits[0].contains("workspaceDirectory()")
        XCTAssertTrue(
            wired,
            "the core must be rooted at workspaceDirectory(), got: \(inits[0])"
        )
    }

    /// The directory is a single derivation, not a repeated recipe.
    ///
    /// The failure this catches is a SECOND site rebuilding the same path by
    /// hand — `applicationSupportDirectory` + `"zeus"` spelled out again. It
    /// would agree today and diverge the first time either copy is edited, and
    /// a divergence here is a guard confining a directory nothing writes to.
    func testTheDirectoryHasExactlyOneDerivation() throws {
        let code = codeLines(try transportSource())
        let derivations = code.filter { $0.contains("applicationSupportDirectory") }
        XCTAssertEqual(
            derivations.count, 1,
            "one derivation of the workspace path, got: \(derivations)"
        )
    }

    /// The behavioural arm: the value is real, absolute, and on disk.
    ///
    /// `workspaceDirectory()` creates the directory as a side effect, so a
    /// returned path that does not exist means the creation failed silently
    /// and `ZeusCore.init` is about to be handed a root that is not there.
    /// The `isEmpty` check is not redundant with `hasPrefix("/")`: an empty
    /// string fails both, but a relative path fails only the second, and a
    /// relative root would resolve against the process CWD — which on iOS is
    /// `/`, not the container.
    func testTheWorkspaceDirectoryIsRealAndAbsolute() {
        let dir = EmbeddedCore.workspaceDirectory()

        XCTAssertFalse(dir.isEmpty, "an empty root would confine the guard to nothing")
        XCTAssertTrue(dir.hasPrefix("/"), "must be absolute, got: \(dir)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir),
            "workspaceDirectory() creates the directory; it must exist at \(dir)"
        )

        // Stable across calls. `ZeusCore.init` is called once from a lazy
        // static, but every other consumer calls this function again — if it
        // returned a fresh temp path per call, the guard's root and the app's
        // files would part company after the first turn.
        XCTAssertEqual(
            dir, EmbeddedCore.workspaceDirectory(),
            "the derivation must be stable across calls"
        )
    }
}
