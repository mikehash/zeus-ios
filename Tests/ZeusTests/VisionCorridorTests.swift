import XCTest
@testable import Zeus

/// The corridor, end to end: a picked image's BYTES reach the transport.
///
/// Every leg above this one in the arc was structural — the seam did not exist,
/// so the only witnessable facts were about text. These are behavioural: a
/// value goes in one end and is asserted at the other, which is the only shape
/// that can detect the silent drop this cut retires.
final class VisionCorridorTests: XCTestCase {

    /// Records what it was asked to carry. Not a stub that answers — it
    /// finishes immediately, so a leg cannot mistake a canned reply for a wire.
    private final class RecordingTransport: SessionTransport {
        private(set) var prompts: [String] = []
        private(set) var images: [[OutboundImage]] = []

        func stream(prompt: String, images: [OutboundImage]) -> AsyncThrowingStream<SessionFrame, Error> {
            prompts.append(prompt)
            self.images.append(images)
            return AsyncThrowingStream { $0.finish() }
        }
    }

    /// The gateway transport under test, pointed at a host that cannot answer.
    /// The refusal must happen at the DOOR — before any request — which is
    /// what makes an unreachable host the right fixture: if the bytes ever
    /// reached the socket this leg would see a network fault instead.
    private static func gateway() -> HTTPTransport {
        HTTPTransport(endpoint: GatewayConfig.Endpoint(url: URL(string: "https://example.invalid")!,
                                                       token: nil),
                      sessionID: SessionIDBox(),
                      credentials: StubCredentialProvider())
    }

    /// The engine has RUN when the agent slot exists, its caret is cleared and
    /// the state is back to ambient — the same terminal condition the failure
    /// suite uses, and for the same reason: `state == .ambient` alone is true
    /// before the turn's Task has executed a line.
    private static func settleTurn(_ engine: SessionEngine, slots: Int = 2) async {
        for _ in 0..<200 {
            if await engine.messages.count == slots,
               await !(engine.messages.last?.streaming ?? true),
               await engine.state == .ambient { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the turn never settled")
    }

    private static let png = OutboundImage(mimeType: "image/png",
                                           bytes: Data([0x89, 0x50, 0x4E, 0x47]))

    // MARK: - RED 5: bytes survive the corridor

    /// 🔴 THE SILENT DROP, RETIRED. Picker outcome → composer → engine →
    /// transport, asserting the BYTES on arrival rather than the shape of the
    /// call. Before this cut the corridor's widest type was `String`, so this
    /// leg was unwritable — which is exactly why the drop went unnoticed.
    func testTheCorridorCarriesBytesFromThePickToTheTransport() async throws {
        let transport = RecordingTransport()
        let engine = await SessionEngine(transport: transport, seed: [])

        let picked = OutboundAttachment.image(Self.png, name: "shot.png")
        await engine.send("what is this", images: picked.images)
        await Self.settleTurn(engine)

        let carried = try XCTUnwrap(transport.images.first)
        XCTAssertEqual(carried.count, 1, "the image did not survive the corridor")
        XCTAssertEqual(carried[0].bytes, Self.png.bytes,
                       "the bytes changed in transit — a re-encode, not a carry")
        XCTAssertEqual(carried[0].mimeType, "image/png")

        // 🔴 AND THE BYTES ARE NOT ALSO IN THE TEXT. An image rides the wire;
        // a path in the prompt would send `read_file` after a file the
        // workspace does not contain.
        let prompt = try XCTUnwrap(transport.prompts.first)
        XCTAssertEqual(prompt, "what is this",
                       "the image leaked into the turn text: \(prompt)")
    }

    /// The POS/NEG pair for the leg above: a prose turn carries NO images, so
    /// "images arrived" is a fact about the attachment and not a constant.
    func testAProseTurnCarriesNoImages() async throws {
        let transport = RecordingTransport()
        let engine = await SessionEngine(transport: transport, seed: [])

        await engine.send("just words")
        await Self.settleTurn(engine)

        XCTAssertEqual(transport.images.first?.isEmpty, true,
                       "VOID: images arrive even when none were attached")
    }

    // MARK: - RED 4: the shipping half is byte-identical

    /// 🔴 REGRESSION GUARD ON THE HALF THAT ALREADY SHIPS. The document route
    /// composes the same turn text it did before the seam widened — same
    /// marker, same position, same absence of images. If this cut had folded
    /// the path into the image type, this is the leg that would red.
    func testTheDocumentRouteProducesTheIdenticalTurnText() async throws {
        let staged = OutboundAttachment.staged("attachments/report.pdf")
        let expected = SessionView.turnText(typed: "summarise",
                                            stagedPath: "attachments/report.pdf")

        let transport = RecordingTransport()
        let engine = await SessionEngine(transport: transport, seed: [])
        await engine.send(SessionView.turnText(typed: "summarise",
                                               stagedPath: staged.stagedPath),
                          images: staged.images)
        await Self.settleTurn(engine)

        XCTAssertEqual(transport.prompts.first, expected)
        XCTAssertTrue(expected.contains("attachments/report.pdf"),
                      "VOID: the reference is absent, so equality is trivial")
        XCTAssertEqual(transport.images.first?.isEmpty, true,
                       "a staged document contributed images")
    }

    /// The two kinds project DIFFERENTLY — the assertion that makes the pair
    /// above meaningful rather than two spellings of one fact.
    func testTheTwoKindsProjectOntoDifferentChannels() {
        let doc = OutboundAttachment.staged("attachments/a.pdf")
        let img = OutboundAttachment.image(Self.png, name: "a.png")

        XCTAssertNotNil(doc.stagedPath)
        XCTAssertNil(img.stagedPath, "an image must not contribute a path")
        XCTAssertTrue(doc.images.isEmpty)
        XCTAssertFalse(img.images.isEmpty, "an image must contribute bytes")
        XCTAssertNotEqual(doc.stagedPath == nil, img.stagedPath == nil)
    }

    // MARK: - RED 2: the gateway refuses honestly

    /// 🔴 `.refused`'s SECOND INHABITANT. The gateway wire has no image field,
    /// so `HTTPTransport` must say so — not drop the bytes and answer as if
    /// the picture had been seen.
    func testTheGatewayRefusesImagesHonestlyRatherThanDroppingThem() async throws {
        let transport = Self.gateway()

        var thrown: Error?
        do {
            for try await _ in transport.stream(prompt: "look", images: [Self.png]) {}
        } catch {
            thrown = error
        }

        let error = try XCTUnwrap(thrown, "the gateway swallowed an image it cannot send")
        guard let te = error as? TransportError,
              case .refused(let detail) = te else {
            return XCTFail("wrong arm — a refusal is not a fault: \(error)")
        }
        XCTAssertTrue(detail.contains("IMAGES"), "the refusal names its subject: \(detail)")
        XCTAssertTrue(detail.contains("LOCAL CORE"),
                      "the refusal names the channel that works: \(detail)")
        // Composed, not fragmentary: what the operator READS must carry no
        // alarm word, because nothing failed.
        let composed = try XCTUnwrap(error.localizedDescription)
        for alarm in ["ERROR", "FAILED", "UNREACHABLE"] {
            XCTAssertFalse(composed.contains(alarm),
                           "a refusal rendered as a fault: \(composed)")
        }
    }

    /// POS control for the leg above: the same transport on a PROSE turn does
    /// not refuse at the door, so the refusal is conditioned on the images and
    /// not on the transport being unreachable.
    func testTheGatewayDoesNotRefuseAProseTurnAtTheDoor() async throws {
        let transport = Self.gateway()
        var thrown: Error?
        do {
            for try await _ in transport.stream(prompt: "look", images: []) {}
        } catch {
            thrown = error
        }
        if let te = thrown as? TransportError, case .refused = te {
            XCTFail("VOID: the door refuses regardless of images")
        }
    }
}
