import XCTest

/// The linked binary's PROVENANCE, asserted rather than assumed.
///
/// `scripts/build-xcframework.sh:174-189` writes a manifest beside the
/// artifact recording every input that can differ between boxes — including
/// `dep-pin`, the `rev` the Rust bridge was compiled against. Until this file
/// existed the census for a READER of that manifest read 0 (POS: the string is
/// greppable, one hit, at the producer). A build record nobody asserts against
/// is a comment with a timestamp: the manifest sat on disk carrying
/// `dep-pin 2a2168cd` while `rust/zeus-core-bridge/Cargo.toml` pinned
/// `fe40ddb8`, and nothing in the suite could see it.
///
/// The gap was not academic. `zeus-agent` differs across exactly that span in
/// LIBRARY code — `lib.rs` grew the `#[cfg(feature = "automation")]` /
/// `#[cfg(not(...))]` pair that our `default-features = false` pin exists to
/// exercise. The binding surface (`src/`) was byte-identical, so the Swift
/// side compiled and ran clean against a `.a` that predated the feature gate.
/// A streamed-reply run in that state is a real token stream through a binary
/// that is NOT the tree's pin, and it would have been reported as the leg
/// passing.
///
/// The property: the sha recorded at build time equals the sha the manifest
/// declares it built from. Not "a build exists" — WHICH build.
final class FrameworkProvenanceTests: XCTestCase {

    // MARK: - substrate

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
    }

    /// VOID rather than fail when the artifact is absent: a fresh checkout does
    /// not carry `Frameworks/` (it is gitignored — the fact Zeus112's HOW-TO
    /// records), and a guard that reds on a legitimately un-built tree teaches
    /// the reader to ignore it. Absent artifact = UNMEASURED, and it says so.
    private func manifestText() throws -> String? {
        let path = repoRoot()
            .appendingPathComponent("Frameworks/ZeusCore.xcframework/zeus-build-manifest.txt")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func manifestValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix("\(key):") {
            return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The 40-char lowercase hex in a string, if there is exactly one. Returns
    /// nil for zero or many: "the first sha I found" is the shape that let a
    /// stale pin ride, and an ambiguous manifest line must VOID, not guess.
    private func soleSHA(_ s: String) -> String? {
        var found: [String] = []
        var run = ""
        for ch in s + " " {
            if ch.isHexDigit && !ch.isUppercase {
                run.append(ch)
            } else {
                if run.count == 40 { found.append(run) }
                run = ""
            }
        }
        return found.count == 1 ? found[0] : nil
    }

    private func cargoRevs() throws -> [String] {
        let toml = try String(
            contentsOf: repoRoot().appendingPathComponent("rust/zeus-core-bridge/Cargo.toml"),
            encoding: .utf8)
        var revs: [String] = []
        for line in toml.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.contains("rev = \"") else { continue }
            guard let start = t.range(of: "rev = \"") else { continue }
            let rest = t[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            revs.append(String(rest[..<end]))
        }
        return revs
    }

    // MARK: - the pin the manifest declares == the pin the tree carries

    func testTheLinkedBinaryWasBuiltAtTheRevTheTreePins() throws {
        guard let text = try manifestText() else {
            return XCTFail("""
                VOID: no Frameworks/ZeusCore.xcframework manifest on this box — \
                there is NO PROVENANCE TO ASSERT. The artifact is gitignored, so \
                a fresh checkout reaches here unmeasured; run \
                scripts/build-xcframework.sh before this suite. This is a FAIL \
                and not a skip on purpose: a skipped provenance leg is a green \
                that means nothing was checked, which is the exact shape that \
                let dep-pin 2a2168cd sit under a tree pinning fe40ddb8.
                """)
        }

        let revs = try cargoRevs()
        // POS: the manifest-reading half is pointless if the Cargo walk is dead.
        XCTAssertGreaterThan(revs.count, 0,
            "VOID: no `rev = \"…\"` found in rust/zeus-core-bridge/Cargo.toml — " +
            "the needle is measuring nothing")

        let distinct = Set(revs)
        XCTAssertEqual(distinct.count, 1,
            "every bridge crate must ride ONE rev — two revs of one repo in a " +
            "lock file is two copies of every shared type. Found: \(distinct.sorted())")

        guard let declared = manifestValue("dep-pin", in: text) else {
            return XCTFail("VOID: manifest carries no `dep-pin:` line — " +
                           "build-xcframework.sh:184 stopped writing it")
        }
        guard let built = soleSHA(declared) else {
            return XCTFail("VOID: `dep-pin: \(declared)` does not contain exactly " +
                           "one 40-char sha — cannot compare")
        }
        guard let pinned = revs.first else { return }

        XCTAssertEqual(built, pinned, """
            the linked xcframework was built at \(built) but the tree pins \
            \(pinned). The Swift side compiles either way — the UniFFI binding \
            surface does not move on every dep bump — so this divergence is \
            INVISIBLE to every other leg in the suite. Re-run \
            scripts/build-xcframework.sh.
            """)
    }

    /// The manifest must also name the artifact's OWN commit, and both slices.
    /// Without the slice line a device-only build passes the pin check and then
    /// fails at embed time on the simulator, which reads as an Xcode fault.
    func testTheManifestRecordsBothSlicesAndItsOwnCommit() throws {
        guard let text = try manifestText() else {
            return XCTFail("VOID: no manifest on this box — no provenance to " +
                           "assert. Run scripts/build-xcframework.sh. FAIL, not skip: " +
                           "an absent artifact must never read as a green.")
        }

        guard let crate = manifestValue("crate-sha", in: text) else {
            return XCTFail("VOID: manifest carries no `crate-sha:` line")
        }
        XCTAssertEqual(crate.count, 40,
            "`crate-sha: \(crate)` is not a full sha — an abbreviated coordinate " +
            "cannot be checked out on another box")

        guard let slices = manifestValue("slices", in: text) else {
            return XCTFail("VOID: manifest carries no `slices:` line")
        }
        XCTAssertTrue(slices.contains("ios-arm64"),
            "device slice missing from `slices: \(slices)`")
        XCTAssertTrue(slices.contains("ios-arm64-simulator"),
            "simulator slice missing from `slices: \(slices)` — device and " +
            "simulator are different PLATFORMS, not different arches")

        // Non-vacuity: the two slice assertions above both pass on a line that
        // reads "ios-arm64-simulator" alone, since it contains "ios-arm64" as a
        // prefix. Assert they are genuinely two entries.
        XCTAssertEqual(slices.split(separator: " ").count, 2,
            "`slices: \(slices)` must name exactly two slices — a substring " +
            "match on the simulator entry satisfies both checks above")

        for key in ["device-sha", "sim-sha"] {
            guard let v = manifestValue(key, in: text) else {
                return XCTFail("VOID: manifest carries no `\(key):` line")
            }
            XCTAssertEqual(v.count, 64,
                "`\(key): \(v)` is not a sha256 of the built archive")
        }
        XCTAssertNotEqual(manifestValue("device-sha", in: text),
                          manifestValue("sim-sha", in: text),
                          "device and simulator archives are byte-identical — " +
                          "one slice was built twice")
    }
}
