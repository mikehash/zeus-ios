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

    /// 🔴 RED 1 — ROUTE 1 NOW ROUTES. The image arm returns `nil`, which is
    /// this layer's word for "proceed", and the corridor below it is what
    /// makes that honest. The previous form of this leg asserted the OPPOSITE
    /// and was correct then: the seam carried prose only, so a PNG had nowhere
    /// to go and refusing was the truthful answer. It is kept inverted rather
    /// than deleted because the inversion is the whole claim of this cut.
    ///
    /// The vacuity risk is real — `nil` is also what a deleted arm returns —
    /// so the leg pairs with the two kinds that MUST still refuse, in the same
    /// invocation. A `refusal` that returned `nil` for everything passes the
    /// first assertion and fails the next two.
    func testAnImageRoutesRatherThanRefusing() throws {
        XCTAssertNil(AttachRoute.refusal(for: .image(mimeType: "image/png")),
                     "an image must reach the vision channel, not a refusal")
        XCTAssertNil(AttachRoute.refusal(for: .image(mimeType: "image/jpeg")))

        // NEG controls, same invocation: the function still says no to the
        // things it must, so the `nil` above is a decision and not a stub.
        XCTAssertNotNil(AttachRoute.refusal(for: .unsupported(reason: ".zip")),
                        "VOID: refusal() returns nil for everything")
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

        // 🔴 THE SUBJECT MOVED ONE LAYER, and the leg follows it rather than
        // being deleted. `RootView` no longer asks the disposition directly:
        // the photo road reaches the same decision without a URL, so BOTH
        // roads now go through `AttachDoor`, which is the single asker. The
        // invariant is unchanged — the view does not carry its own copy — and
        // the site that proves it is the door.
        let door = try XCTUnwrap(sources.first { $0.name == "AttachDoor.swift" })
        XCTAssertTrue(door.body.contains("AttachRoute.refusal(for: kind)"),
                      "the pick path must ask the shared decision")

        let root = try XCTUnwrap(sources.first { $0.name == "RootView.swift" })
        XCTAssertFalse(root.body.contains("AttachRoute.refusal("),
                       "the view asks the disposition directly again — two askers is "
                       + "how the file and photo roads drift apart")
        XCTAssertTrue(root.body.contains("AttachDoor.outcome("),
                      "the view must still reach the disposition THROUGH the door")
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
        XCTAssertTrue(route.body.contains("AttachmentKind"),
                      "VOID: the corpus read produced nothing")
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
