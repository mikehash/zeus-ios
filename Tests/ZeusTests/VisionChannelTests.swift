import XCTest
@testable import Zeus

/// E1 — the Swift half of the vision channel.
///
/// The Rust half (bridge `cargo test`) proves a synthetic `Attachment` reaches
/// the real `zeus_llm::multimodal` formatter as base64 and that a non-image is
/// refused at the door. What THIS file can see, and the Rust legs structurally
/// cannot, is the Swift side of the seam: that the parameter exists on the
/// generated surface, that the one production caller threads it, and that the
/// permission we deliberately never request stays unrequested.
///
/// ⚠️ Aperture: source census + generated-binding reads. Nothing here sends a
/// turn — that needs a provider and a network round trip — so every claim is
/// about SHAPE, and none of it is evidence the model saw an image on a device.
final class VisionChannelTests: XCTestCase {

    // MARK: - Source reading

    /// Production source with comments stripped.
    ///
    /// The strip is an INSTRUMENT, so every caller asserts a known-present
    /// surviving token before trusting a negative: a strip that ate the body
    /// makes every `XCTAssertFalse` below it pass vacuously, and it passes in
    /// the direction that looks like success. Sixth arrival of that fault on
    /// this app; it is cheap to control for and expensive to miss.
    private static func codeOnly(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func source(_ relative: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The seam

    /// The one production caller threads the images parameter.
    ///
    /// Structural because the behavioural version is unreachable: `send`
    /// blocks on a live client. What a census CAN say is that the call names
    /// the parameter — and a call that dropped it would not compile, so the
    /// value of this leg is the second assertion: that the array is the
    /// EMPTY-and-explicit form rather than a call that quietly lost its way
    /// back to a text-only entry point.
    func testTheEmbeddedTransportThreadsTheImagesParameter() throws {
        let code = Self.codeOnly(try Self.source("Sources/ZeusApp/EmbeddedTransport.swift"))

        XCTAssertTrue(code.contains("func stream(prompt: String, images: [OutboundImage])"),
                      "POS control absent — the source read produced nothing, "
                      + "so every negative below is vacuous")

        XCTAssertTrue(code.contains("try core.send(sessionId: id,"),
                      "the send call no longer threads images")

        // 🔴 THE EMPTY LITERAL IS GONE. It was the whole reason the corridor
        // was dark: a value no caller could influence. Its absence is the
        // structural half of "real bytes travel"; the behavioural half is
        // `testTheCorridorCarriesBytesFromThePickToTheTransport`.
        XCTAssertFalse(code.contains("images: []"),
                       "the hardcoded empty image list is back")
        XCTAssertTrue(code.contains("ImageAttachment(mimeType: $0.mimeType, bytes: $0.bytes)"),
                      "the app type no longer maps to the FFI record here")

        // There must be exactly ONE call. A second would be the text-arm /
        // image-arm pair we deliberately did not build: two sides whose
        // difference no mutation could detect, because an empty array through
        // `run_with_attachments` IS the old `run_structured` behaviour.
        XCTAssertEqual(code.components(separatedBy: "core.send(").count - 1, 1,
                       "more than one send path — the arm-pair this design "
                       + "rejected has reappeared")
    }

    /// The generated surface carries the parameter and the record.
    ///
    /// Reads the BINDINGS, not our source: this is the leg that reds when the
    /// checked-in `zeus_core_bridge.swift` goes stale against the crate — the
    /// exact drift that produced a broken uniffi check on the M4 arc.
    func testTheGeneratedBindingCarriesTheImageRecord() throws {
        let bindings = try Self.source("Sources/ZeusCoreFFI/zeus_core_bridge.swift")

        XCTAssertTrue(bindings.contains("public struct ImageAttachment"),
                      "the regenerated binding has no ImageAttachment — the "
                      + "checked-in file is stale against the crate")
        XCTAssertTrue(bindings.contains("images: [ImageAttachment]"),
                      "send's generated signature does not take images")
        XCTAssertTrue(bindings.contains("case NotAnImage"),
                      "the typed vision refusal never reached Swift")
    }

    /// The record is constructible from the two fields a phone can supply.
    ///
    /// Behavioural, and it is the only leg here that executes anything: if the
    /// Record ever grew a `sourceUrl` a `PhotosPicker` cannot populate, this
    /// stops compiling — which is the point. A field Swift must pass and can
    /// only pass as nil is a question with one legal answer.
    func testTheImageRecordIsTheTwoFieldsAPickerCanProduce() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let attachment = ImageAttachment(mimeType: "image/png", bytes: Data(png))

        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.bytes.count, 4,
                       "bytes did not survive construction")
        XCTAssertFalse(attachment.bytes.isEmpty,
                       "an empty payload would encode a well-formed envelope "
                       + "around nothing")
    }

    // MARK: - The allow-list we did NOT write

    /// No Swift-side vision allow-list, and no provider or model literals
    /// deciding what can see.
    ///
    /// The model gate lives at `zeus-llm/capabilities:548`, which returns an
    /// operator-readable sentence and, on refusal, STRIPS the images and tells
    /// the model to say it cannot see. A second gate on this side would drift
    /// the day a provider ships a new vision model — and it would drift
    /// SILENTLY, refusing a capable model with a confident sentence.
    func testNoSwiftSideVisionAllowListDecidesWhatCanSee() throws {
        let code = Self.codeOnly(try Self.source("Sources/ZeusApp/EmbeddedTransport.swift"))

        XCTAssertTrue(code.contains("static func describe("),
                      "POS control absent — the negatives below are vacuous")

        for literal in ["visionModels", "supportsVision", "canSeeImages",
                        "gpt-4o", "claude-3", "visionCapable"] {
            XCTAssertFalse(code.contains(literal),
                           "\(literal) — a Swift-side vision gate has appeared; "
                           + "the core owns this answer")
        }
    }

    /// The encoding is dialect-owned: no base64 and no content-part shape on
    /// this side of the bridge.
    ///
    /// `zeus_llm::multimodal` emits Anthropic's `source.type=base64` and
    /// OpenAI's `image_url` from ONE `Attachment`, selected by provider.
    /// Anything above `zeus-llm` choosing between them is a second source for a
    /// fact the dialect table already owns.
    func testTheEncodingIsNotDuplicatedInSwift() throws {
        let code = Self.codeOnly(try Self.source("Sources/ZeusApp/EmbeddedTransport.swift"))

        XCTAssertTrue(code.contains("AsyncThrowingStream"),
                      "POS control absent — the negatives below are vacuous")

        for shape in ["base64EncodedString", "image_url", "\"type\": \"image\"",
                      "data:image/"] {
            XCTAssertFalse(code.contains(shape),
                           "\(shape) — the content-part encoding has been "
                           + "duplicated above zeus-llm")
        }
    }

    /// `NSPhotoLibraryUsageDescription` stays ABSENT, and its absence is pinned.
    ///
    /// Not an oversight and not a bug to fix: `PhotosPicker` runs out of
    /// process and needs no usage description. Adding the key would request a
    /// permission we never exercise — a consent prompt for an access that never
    /// happens, which is the same dishonesty as a control that narrates an act
    /// it does not perform, pointed at the operator's privacy settings.
    ///
    /// This leg is what stops E2 from "fixing" the absence by adding it.
    func testThePhotoLibraryPermissionIsNeverRequested() throws {
        let manifest = try Self.source("project.yml")

        XCTAssertTrue(manifest.contains("NSMicrophoneUsageDescription"),
                      "POS control absent — the manifest read produced nothing, "
                      + "so the negative below proves nothing")

        XCTAssertFalse(manifest.contains("NSPhotoLibraryUsageDescription"),
                       "a photo-library permission is being requested. "
                       + "PhotosPicker is out-of-process and needs none — if a "
                       + "picker now needs this key, it is the WRONG picker")
        XCTAssertFalse(manifest.contains("NSPhotoLibraryAddUsageDescription"),
                       "a photo-library WRITE permission is being requested; "
                       + "nothing in this app writes to the library")
    }

    /// The image path is an ADDITION beside `stage_attachment`, not a
    /// replacement for it.
    ///
    /// The file channel still works and still matters: a text file staged into
    /// the confined workspace is read by the model through `read_file`, which
    /// is the correct shape for text and the wrong one for a binary. Both
    /// channels exist; the refusal sentence points from one to the other.
    func testTheFileStagingChannelSurvivedTheVisionCut() throws {
        let session = Self.codeOnly(try Self.source("Sources/ZeusApp/SessionView.swift"))

        XCTAssertTrue(session.contains("fileImporter"),
                      "the file attach channel was removed by the vision cut — "
                      + "the two are siblings, not alternatives")
    }
}
