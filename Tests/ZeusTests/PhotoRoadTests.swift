import XCTest
@testable import Zeus

/// The photo road: a picked image reaches the vision corridor, and the app
/// still asks for no photo-library permission.
///
/// The file road is `SessionStageTests` / `AttachRouteTests`; this file exists
/// because the photo road obtains bytes DIFFERENTLY (out of process, no URL,
/// no security scope) and must dispose of them IDENTICALLY.
final class PhotoRoadTests: XCTestCase {

    // MARK: - Corpus helpers

    /// Production source with comments stripped, both forms.
    ///
    /// The block-comment half is not defensive: `Sources/ZeusCoreFFI` is
    /// GENERATED
    /// and UniFFI renders Rust doc comments into Swift block comments, one of
    /// which contains the word `PhotosPicker` describing why a phone
    /// attachment is bytes. A `//`-only strip counted that SENTENCE as a
    /// picker — the incident that widened `SessionStageTests.codeOnly`.
    private static func codeOnly(_ source: String) -> String {
        let lineStripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex ..< slash.lowerBound]
            }
            .joined(separator: "\n")

        var out = ""
        var depth = 0
        var i = lineStripped.startIndex
        let open = "/" + "*", close = "*" + "/"
        while i < lineStripped.endIndex {
            if lineStripped[i...].hasPrefix(open) {
                depth += 1
                i = lineStripped.index(i, offsetBy: 2)
            } else if lineStripped[i...].hasPrefix(close), depth > 0 {
                depth -= 1
                i = lineStripped.index(i, offsetBy: 2)
            } else {
                if depth == 0 { out.append(lineStripped[i]) }
                i = lineStripped.index(after: i)
            }
        }
        return out
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The door: an image never reaches the stage

    /// 🔴 THE LEG THE WHOLE ARC TURNS ON. A picked image becomes an
    /// `OutboundImage` carrying the bytes, and the staging closure is NEVER
    /// called.
    ///
    /// Asserted by a closure that RECORDS its calls rather than by reading the
    /// source for a `return` before the stage: a comment can claim an early
    /// return and a refactor can move it. An uncalled closure is the behaviour
    /// itself.
    ///
    /// Staging a PNG would "work" — a file would land in the workspace and the
    /// composer would show a path — and the model would then `read_file` a
    /// binary and read it as garbage. A silently-wrong success is the outcome
    /// this arc has been chasing since the first attach cut.
    func testAPickedImageCarriesBytesAndIsNeverStaged() {
        var stageCalls: [String] = []
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let outcome = AttachDoor.outcome(fileName: "PHOTO.PNG",
                                         bytes: bytes,
                                         kind: .image(mimeType: "image/png"),
                                         stage: { name, _ in
                                             stageCalls.append(name)
                                             return "attachments/PHOTO.PNG"
                                         })

        guard case .attachedImage(let image, let name) = outcome else {
            return XCTFail("an image did not take the vision arm: \(outcome)")
        }
        XCTAssertEqual(image.bytes, bytes, "the bytes must survive the door unchanged")
        XCTAssertEqual(image.mimeType, "image/png",
                       "the mime must be the one the CORE judged, not a re-derivation")
        XCTAssertEqual(name, "PHOTO.PNG")
        XCTAssertEqual(stageCalls, [],
                       "an image was written to the workspace — the model would read a "
                       + "binary as garbage, and the composer would show a credible lie")
    }

    /// The control for the leg above, in the same file: a DOCUMENT does reach
    /// the stage. Without it, a door that refused everything would pass
    /// `stageCalls == []` for the wrong reason.
    func testADocumentStillReachesTheStage() {
        var stageCalls: [String] = []

        let outcome = AttachDoor.outcome(fileName: "REPORT.PDF",
                                         bytes: Data("%PDF-1.7".utf8),
                                         kind: .document(extension: "pdf"),
                                         stage: { name, _ in
                                             stageCalls.append(name)
                                             return "attachments/REPORT.PDF"
                                         })

        XCTAssertEqual(outcome, .staged("attachments/REPORT.PDF"))
        XCTAssertEqual(stageCalls, ["REPORT.PDF"],
                       "POS: the document road still stages — the image leg's empty "
                       + "call list is an absence, not a door that refuses everything")
    }

    /// An unsupported pick refuses at the door, naming its subject, and does
    /// not stage.
    func testAnUnsupportedPickRefusesWithoutStaging() {
        var staged = false
        let outcome = AttachDoor.outcome(fileName: "ARCHIVE.ZIP",
                                         bytes: Data([0x50, 0x4B, 0x03, 0x04]),
                                         kind: .unsupported(reason: ".zip"),
                                         stage: { _, _ in staged = true; return "x" })

        guard case .failed(let why) = outcome else {
            return XCTFail("an unsupported file was accepted: \(outcome)")
        }
        XCTAssertTrue(why.uppercased().contains(".ZIP"),
                      "the refusal must name its subject — '\(why)'")
        XCTAssertFalse(staged, "a refused file must not reach the workspace")
    }

    /// Empty bytes refuse before any classification is trusted.
    func testEmptyBytesRefuseAtTheDoor() {
        var staged = false
        let outcome = AttachDoor.outcome(fileName: "EMPTY.TXT",
                                         bytes: Data(),
                                         kind: .text,
                                         stage: { _, _ in staged = true; return "x" })

        XCTAssertEqual(outcome, .failed("THAT FILE IS EMPTY — NOTHING STAGED"))
        XCTAssertFalse(staged)
    }

    // MARK: - One door, two roads

    /// 🔴 BOTH ROADS GO THROUGH THE SAME DOOR, asserted structurally because
    /// there is no runtime seam that can observe "which function decided".
    ///
    /// The defect this refuses is a photo path that grew its own `if case
    /// .image` — correct on the day it was written and silently divergent the
    /// first time the file road's disposition changes. One decision, one
    /// definition, two callers.
    func testTheDispositionHasOneDefinitionAndBothRoadsCallIt() throws {
        let root = Self.codeOnly(try Self.source("Sources/ZeusApp/RootView.swift"))

        XCTAssertEqual(Self.count("AttachDoor.outcome(", in: root), 2,
                       "expected exactly two callers — the file road and the photo road")
        XCTAssertEqual(Self.count("case .image(let mimeType) = kind", in: root), 0,
                       "the view re-implements the image disposition the door owns")

        let door = Self.codeOnly(try Self.source("Sources/ZeusApp/AttachDoor.swift"))
        XCTAssertEqual(Self.count("static func outcome(", in: door), 1,
                       "the door must have exactly one definition")
        // POS control, same invocation: a code token that survived the strip,
        // so the zero above is an absence and not an empty corpus.
        XCTAssertGreaterThan(Self.count("private func stagePhoto(", in: root), 0,
                             "VOID: the source corpus did not survive the comment strip")
    }

    /// The photo road classifies by asking the CORE, exactly as the file road
    /// does — it does not carry a second opinion about what an image is.
    func testThePhotoRoadClassifiesThroughTheSameCrossing() throws {
        let root = Self.codeOnly(try Self.source("Sources/ZeusApp/RootView.swift"))

        XCTAssertEqual(Self.count("classifyAttachment(fileName:", in: root), 1,
                       "the bridge crossing must have ONE call site both roads reach")
        XCTAssertEqual(Self.count("Self.classify(fileName:", in: root), 2,
                       "both roads must reach that crossing through the shared helper")
    }

    /// The composer's photo control is wired to a real load, not to a flag.
    func testTheComposerCarriesAPhotosPickerBoundToTheSeam() throws {
        let view = Self.codeOnly(try Self.source("Sources/ZeusApp/SessionView.swift"))

        XCTAssertTrue(view.contains("PhotosPicker(selection: $photoItem, matching: .images)"),
                      "the photo control is absent from the composer")
        XCTAssertTrue(view.contains("onStagePhoto("),
                      "the picker does not reach the staging seam — bytes would be loaded "
                      + "and dropped, which is the dead-pipe shape this arc retired")
        XCTAssertTrue(view.contains("loadTransferable(type: Data.self)"),
                      "the picked item's bytes are never loaded")
        XCTAssertTrue(view.contains("fileImporter"),
                      "POS: the file road survived — the two pickers are siblings, "
                      + "not alternatives")
    }

    /// The photo seam is wired at the one production call site.
    func testTheOwnerSuppliesThePhotoSeam() throws {
        let root = Self.codeOnly(try Self.source("Sources/ZeusApp/RootView.swift"))

        XCTAssertTrue(root.contains("onStagePhoto: stagePhoto(fileName:bytes:)"),
                      "the composer's photo seam keeps its refusing default in "
                      + "production — every pick would report NO CORE ON THIS DEVICE")
        XCTAssertTrue(root.contains("onStage: stage"),
                      "POS: the file seam is still wired beside it")
    }

    // MARK: - The permission that is not requested

    /// 🔴 THE PIN, RESTATED WITH ITS REASON AT THE NEW SITE.
    ///
    /// `PhotosPicker` presents an out-of-process sheet: the app receives the
    /// bytes the operator chose and never gains library access, so
    /// `NSPhotoLibraryUsageDescription` is not merely unnecessary — adding it
    /// would prompt for a capability this build does not have.
    ///
    /// The in-process UIKit spellings are censused in the same invocation:
    /// they are the only way this key could become required, so their absence
    /// is why the absence above is stable.
    func testThePhotoLibraryPermissionIsStillNeverRequested() throws {
        let manifest = try Self.source("project.yml")

        XCTAssertFalse(manifest.contains("NSPhotoLibraryUsageDescription"),
                       "a photo-library permission is being requested. PhotosPicker is "
                       + "out-of-process and needs none — if a picker was added that "
                       + "does, it is the wrong picker, not a missing key")
        XCTAssertTrue(manifest.contains("CFBundle"),
                      "POS: the manifest was read — the absence above is an absence")

        let view = Self.codeOnly(try Self.source("Sources/ZeusApp/SessionView.swift"))
        for inProcess in ["UIImagePickerController", "PHPickerViewController"] {
            XCTAssertFalse(view.contains(inProcess),
                           "\(inProcess) runs in-process and WOULD require the key")
        }
    }
}
