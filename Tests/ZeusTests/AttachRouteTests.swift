import XCTest
@testable import Zeus

/// The four routes, at the DISPOSITION layer.
///
/// The classification itself is guarded in Rust (`classify_tests`, four named
/// reds) because every predicate there is core-owned. These legs guard the
/// other half: what the OPERATOR sees when a kind cannot be carried. A kind
/// classified correctly and then dropped silently is the same defect as a
/// misclassification, and only this layer can see it.
final class AttachRouteTests: XCTestCase {

    /// ROUTE 1 — an image is REFUSED, and the refusal says why and names the
    /// mime. Not staged: `read_file` on a PNG returns garbage while the
    /// transcript claims the file was attached.
    func testAnImageIsRefusedHonestlyUntilTheSeamCarriesIt() throws {
        let why = try XCTUnwrap(AttachRoute.refusal(for: .image(mimeType: "image/png")),
                                "an image must not fall through to the stage")
        XCTAssertTrue(why.contains("IMAGE/PNG"), "the mime is the subject: \(why)")
        XCTAssertTrue(why.contains("VISION CHANNEL"), "the reason names the channel: \(why)")
        // NOT a fault. `StageOutcome.failed` renders verbatim, so an alarm word
        // here reads to the operator as a broken app rather than a file we
        // cannot yet carry — the `LOCAL CORE ERROR` defect one commit back.
        for alarm in ["ERROR", "FAILED", "CRASH"] {
            XCTAssertFalse(why.contains(alarm), "a refusal is not a fault: \(why)")
        }
    }

    /// ROUTE 4 — unsupported is refused with a NAMEABLE subject, both when
    /// there is an extension and when there is not.
    func testAnUnsupportedFileIsRefusedWithItsSubjectNamed() throws {
        let zip = try XCTUnwrap(AttachRoute.refusal(for: .unsupported(reason: ".zip")))
        XCTAssertTrue(zip.contains(".ZIP"), "the extension is the subject: \(zip)")

        // Extensionless: the file NAME is the subject, because there is no
        // extension to name and a subjectless refusal is unactionable.
        let blob = try XCTUnwrap(AttachRoute.refusal(for: .unsupported(reason: "blob")))
        XCTAssertTrue(blob.contains("BLOB"), "the file name is the subject: \(blob)")

        // VACUITY CONTROL: the two refusals are DIFFERENT strings, so a leg
        // satisfied by a constant cannot pass both.
        XCTAssertNotEqual(zip, blob)
    }

    /// ROUTES 2 and 3 — a document and a text file PROCEED. `nil` is the
    /// whole contract: any string here is a refusal, and refusing a `.pdf` or
    /// a `.md` is precisely what merakizzz asked us to stop doing.
    func testDocumentsAndTextProceedToTheStage() {
        XCTAssertNil(AttachRoute.refusal(for: .document(extension: "pdf")))
        XCTAssertNil(AttachRoute.refusal(for: .document(extension: "docx")))
        XCTAssertNil(AttachRoute.refusal(for: .text))
    }

    /// The disposition has exactly ONE production definition and the view
    /// CALLS it rather than carrying its own copy.
    ///
    /// Structural, and it guards the class that has now arrived five times on
    /// this app: a correct decision whose only caller is a private view body
    /// is unreachable from every leg, so a mutation deleting it leaves the
    /// suite green. This leg is what makes the extraction load-bearing rather
    /// than cosmetic.
    func testTheRoutingDecisionHasOneHomeAndTheViewCallsIt() throws {
        let sources = try Self.sourceFiles()

        let definitions = sources.filter { $0.body.contains("static func refusal(for kind: AttachmentKind)") }
        XCTAssertEqual(definitions.count, 1, "one definition, found: \(definitions.map(\.name))")
        XCTAssertEqual(definitions.first?.name, "AttachRoute.swift")

        let root = try XCTUnwrap(sources.first { $0.name == "RootView.swift" })
        XCTAssertTrue(root.body.contains("AttachRoute.refusal(for: kind)"),
                      "the pick path must ask the shared decision")
        // The view must not re-derive a kind by hand. POS control below proves
        // the strip did not eat the body.
        XCTAssertFalse(root.body.contains("hasPrefix(\"image/\")"),
                       "no Swift reimplementation of the core's predicate")
        XCTAssertTrue(root.body.contains("classifyAttachment(fileName:"),
                      "POS control: the surviving call is present")
    }

    /// The bridge is the only thing that decides what an image IS.
    ///
    /// A Swift mime allow-list would drift the day a format is added, and the
    /// ruling that banned it is the same one that put `is_image` on the core
    /// type. `UTType` is exempt by construction: it NAMES a candidate mime the
    /// core then judges, and it is the system's table, not ours.
    func testNoSwiftSideMimeAllowListExists() throws {
        for file in try Self.sourceFiles() {
            for banned in ["\"image/jpeg\"", "\"image/gif\"", "\"image/webp\""] {
                XCTAssertFalse(file.body.contains(banned),
                               "\(file.name) carries a mime literal: \(banned)")
            }
        }
        // POS CONTROL, same invocation: a literal that IS present, so a census
        // reading an empty corpus cannot pass this vacuously.
        let route = try XCTUnwrap(try Self.sourceFiles().first { $0.name == "AttachRoute.swift" })
        XCTAssertTrue(route.body.contains("VISION CHANNEL"))
    }

    // MARK: - Corpus

    private static func sourceFiles() throws -> [(name: String, body: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("Sources/ZeusApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(names.count, 10, "corpus control: the source dir was found")
        return try names.map { (name: $0, body: try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
    }
}
