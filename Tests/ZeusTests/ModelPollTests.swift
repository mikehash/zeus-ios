import XCTest
@testable import Zeus

/// The MODEL picker's rules, driven directly.
///
/// APERTURE, STATED: `ModelPoll` is the whole of what can be wrong about
/// polling EXCEPT the two lines in the SwiftUI body that call it. Those are
/// unreachable in this target (no ViewInspector) and are guarded by the
/// source-grep in `CommissionStoreTests` — a weaker instrument, named as one.
final class ModelPollTests: XCTestCase {

    private struct Refusal: Error {}

    // MARK: - The three states

    func testAFreshPollHasNothingToSay() {
        let poll = ModelPoll()
        XCTAssertEqual(poll.state, .idle)
        XCTAssertNil(poll.statusLine, "idle is not a sentence — nothing has been asked")
        XCTAssertTrue(poll.offeredModels.isEmpty)
    }

    func testAnInFlightPollSaysSoRatherThanLookingEmpty() {
        var poll = ModelPoll()
        _ = poll.begin()
        XCTAssertEqual(poll.state, .fetching)
        XCTAssertEqual(poll.statusLine, "FETCHING MODELS…")
        XCTAssertTrue(poll.offeredModels.isEmpty,
                      "a pending request offers nothing yet — and must not be confused with a list")
    }

    func testACatalogBecomesTheOfferedList() {
        var poll = ModelPoll()
        let token = poll.begin()
        XCTAssertTrue(poll.accept(.success(["claude-opus-4", "claude-sonnet-4"]),
                                  generation: token, label: "Anthropic"))
        XCTAssertEqual(poll.offeredModels, ["claude-opus-4", "claude-sonnet-4"])
        XCTAssertNil(poll.statusLine,
                     "the list is the statement; a caption beside it would be noise")
    }

    /// THE FOLD, ONE LAYER ABOVE THE BRIDGE'S OWN.
    ///
    /// `classify_catalog_result` folds an empty vector from a no-live-arm
    /// provider into `Unsupported`. This is the belt to that's braces: if an
    /// empty vector ever reaches Swift, rendering it as a zero-row picker
    /// would state that the provider serves no models — a claim we have no
    /// evidence for. The two folds are not redundant: the bridge's decides on
    /// the ARM, this one decides on the VECTOR, and only this one runs when
    /// the bridge is a test double.
    func testAnEmptyCatalogIsNotAnEmptyPicker() {
        var poll = ModelPoll()
        let token = poll.begin()
        poll.accept(.success([]), generation: token, label: "Anthropic")
        XCTAssertEqual(poll.state, .unavailable("COULDN'T REACH ANTHROPIC — TYPE A MODEL"))
        XCTAssertTrue(poll.offeredModels.isEmpty)
        XCTAssertNotEqual(poll.state, .listed([]),
                          "an empty list and an unreachable provider must not be one state")
    }

    func testARefusalNamesTheProviderAndTheNextAction() {
        var poll = ModelPoll()
        let token = poll.begin()
        poll.accept(.failure(Refusal()), generation: token, label: "Groq")
        XCTAssertEqual(poll.statusLine, "COULDN'T REACH GROQ — TYPE A MODEL")
        XCTAssertTrue(poll.offeredModels.isEmpty,
                      "a refusal offers no rows — the free-text field is the way through")
    }

    /// The label is rendered, not the wire id. Same rule the provider rows
    /// hold one file over: `ANTHROPIC` upper-cased from the id is a wire value
    /// leaking into a display form.
    func testTheSentenceCarriesTheLabelNotTheWireID() {
        XCTAssertEqual(ModelPoll.unreachable("OpenRouter"),
                       "COULDN'T REACH OPENROUTER — TYPE A MODEL")
    }

    // MARK: - Staleness

    /// THE DEFECT THIS TYPE EXISTS FOR.
    ///
    /// Two requests in flight, the OLDER one answering last. Without the
    /// generation the last RESPONSE wins and a stale refusal replaces a live
    /// catalog — the operator sees `COULDN'T REACH` for a key that works.
    func testALateAnswerFromAnOlderRequestIsDropped() {
        var poll = ModelPoll()
        let first = poll.begin()
        let second = poll.begin()
        XCTAssertNotEqual(first, second, "each request must be distinguishable from the last")

        XCTAssertTrue(poll.accept(.success(["live-model"]), generation: second, label: "Anthropic"))
        XCTAssertFalse(poll.accept(.failure(Refusal()), generation: first, label: "Anthropic"),
                       "the older request's answer must be DROPPED, not applied")
        XCTAssertEqual(poll.offeredModels, ["live-model"],
                       "the newest request's answer survives the older one landing after it")
    }

    /// A provider switch must not be repairable by a result that was asked
    /// for under the PREVIOUS provider — the wrong-subject defect, wearing a
    /// timing costume.
    func testAResultForTheAbandonedProviderCannotLandUnderTheNewOne() {
        var poll = ModelPoll()
        let old = poll.begin()
        poll.reset()   // operator tapped a different provider row
        XCTAssertEqual(poll.state, .idle)
        XCTAssertFalse(poll.accept(.success(["gpt-4o"]), generation: old, label: "OpenAI"))
        XCTAssertEqual(poll.state, .idle,
                       "the abandoned provider's catalog must not appear under the new one")
    }

    /// The generation is monotonic ACROSS a reset. If `reset` returned the
    /// counter to zero, the next `begin` would re-issue a token an in-flight
    /// request already holds, and that request would be accepted as fresh.
    func testResetDoesNotRecycleAGenerationAnInFlightRequestHolds() {
        var poll = ModelPoll()
        let first = poll.begin()
        poll.reset()
        let second = poll.begin()
        XCTAssertGreaterThan(second, first)
        XCTAssertFalse(poll.accept(.success(["stale"]), generation: first, label: "Ollama"))
    }

    // MARK: - The free-text field survives every state

    /// THE CENSUS THAT KEEPS 13 OF 26 PROVIDERS ARMABLE.
    ///
    /// Only 13 crate arms have a live catalog; the rest are folded to
    /// `Unsupported` at the bridge. If the screen ever replaced the MODEL
    /// field with the picker, those providers would be unarmable — which is
    /// the Ollama-only defect in a new costume. The field's `TextField` must
    /// be OUTSIDE any branch keyed on the poll state.
    func testTheModelFieldIsNotGatedOnTheCatalog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("TextField(\"\", text: $modelText"),
                      "POS control: the grep is reading the file that owns the field")
        // The field is rendered under `if let selected` — a PROVIDER check —
        // and never under a poll-state check. A picker-only branch would read
        // `if case .listed` around it.
        XCTAssertFalse(src.contains("if case .listed = modelPoll.state"),
                       "the free-text field must never be gated on the catalog arriving")
        XCTAssertTrue(src.contains("modelPoll.offeredModels.isEmpty"),
                      "the LIST is the thing gated on the catalog, not the field")
    }

    /// The debounce is a named policy, not a magic number inside a sleep.
    func testTheDebounceIsNamedWhereItCanBeFound() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("pollDebounce"),
                      "POS control plus the claim: the window has a name")
        XCTAssertTrue(src.contains("try? await Task.sleep(nanoseconds: Self.pollDebounce)"),
                      "the sleep must read the named policy, not a literal beside it")
        XCTAssertFalse(src.contains("Task.sleep(nanoseconds: 450_000_000)"),
                       "NEG control: the literal must not survive alongside the name")
    }

    /// The poll must be CANCELLED before a new one is scheduled, or a fast
    /// typist opens one live HTTP request per keystroke from a phone.
    func testKeyEntryCancelsThePendingPollBeforeSchedulingAnother() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/Commissioning.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("pollTask?.cancel()"),
                      "the in-flight debounce must be cancelled, not left to fire")
        XCTAssertTrue(src.contains(".onChange(of: keyText)"),
                      "key entry is what makes the catalog askable, so it is what triggers the poll")
    }
}
