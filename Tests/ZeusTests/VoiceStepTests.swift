import XCTest
@testable import Zeus

/// Commit 4 of the voice wiring: the optional onboarding `voice` step.
///
/// The compiler names the exhaustive sites (`narration`, `Backstep.entering`,
/// `stepContent`). It does NOT name the one that makes the step reachable —
/// the routes CTA's `step = …` — so that edge is guarded here by source.
final class VoiceStepTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "voice-step-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func codeLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// The lines of one computed property: from its declaration to the next
    /// `private var ` / `private func ` at the same file.
    private func body(of decl: String, in code: [String]) -> [String]? {
        guard let start = code.firstIndex(where: { $0.contains(decl) }) else { return nil }
        let rest = code[(start + 1)...]
        let end = rest.firstIndex(where: {
            $0.hasPrefix("private var ") || $0.hasPrefix("private func ")
        }) ?? code.endIndex
        return Array(code[start..<end])
    }

    private func choice(_ id: String, keyed: Bool) -> VoiceProviderChoice {
        VoiceProviderChoice(id: id, label: id, dialect: .openAiRealtime, hasKey: keyed)
    }

    // MARK: - Order

    func testVoiceSitsBetweenRoutesAndNodes() {
        let all = CommissioningStep.allCases
        guard let r = all.firstIndex(of: .routes), let v = all.firstIndex(of: .voice),
              let n = all.firstIndex(of: .nodes)
        else { return XCTFail("VOID: a step is missing from allCases") }
        XCTAssertEqual(v, r + 1)
        XCTAssertEqual(n, v + 1)
        XCTAssertEqual(all.count, 8, "the rail denominator moved 7 → 8 with this step")
        XCTAssertEqual(CommissioningStep(rawValue: "voice"), .voice, "-zeusStep voice parses")
    }

    // MARK: - Reachability (the edge the compiler does not name)

    /// The routes CTA must advance to `.voice`. Left at `.nodes`, the step
    /// compiles, renders under `-zeusStep voice`, passes every test of its
    /// own — and no operator ever sees it.
    func testRoutesAdvancesIntoVoice() throws {
        let code = try codeLines("Commissioning.swift")
        guard let routes = body(of: "private var routesStep", in: code)
        else { return XCTFail("VOID: routesStep not found") }
        XCTAssertTrue(routes.contains { $0.contains("recordRoutesChoice(") },
                      "POS: read the real routes CTA")
        XCTAssertEqual(routes.filter { $0.contains("step = .voice") }.count, 1)
        XCTAssertEqual(routes.filter { $0.contains("step = .nodes") }.count, 0,
                       "routes must not skip over the voice step")
    }

    /// Voice advances to `.nodes`, through one control, and writes nothing
    /// itself: the only preference touch is `voiceSheets.pick`, the only key
    /// route is `addKey` → `KeyOnly`.
    func testVoiceStepAdvancesToNodesAndWritesNothingItself() throws {
        let code = try codeLines("Commissioning.swift")
        guard let voice = body(of: "private var voiceStep", in: code)
        else { return XCTFail("VOID: voiceStep not found") }
        let joined = voice.joined(separator: "\n")
        XCTAssertTrue(joined.contains("voiceSheets.pick(id)"), "POS: pick routes through the sheets value")
        XCTAssertTrue(joined.contains("voiceSheets.addKey(id)"), "POS: add-key raises")
        XCTAssertEqual(voice.filter { $0.contains("step = .nodes") }.count, 1)
        for banned in ["RealtimeProviderPreference.set(", "setProviderKey(", "providerKey(for:",
                       "recordRoutesChoice(", "SecureField", "UserDefaults", "commission."] {
            XCTAssertFalse(joined.contains(banned), "voice step must not contain `\(banned)`")
        }
    }

    /// The add-key sheet onboarding presents is KEY-ONLY — the route the
    /// previous step recorded cannot be repointed by a voice key.
    func testOnboardingAddKeyIsKeyOnly() throws {
        let code = try codeLines("Commissioning.swift")
        let joined = code.joined(separator: "\n")
        XCTAssertTrue(joined.contains("RoutePicker.KeyOnly("), "POS: the key-only sheet is wired")
        XCTAssertTrue(joined.contains("onSaved: { saved in voiceSheets.keySaved(saved) }"))
        XCTAssertEqual(code.filter { $0.contains("RoutePicker(keys:") }.count, 1,
                       "exactly one full route picker — the routes step's own")
        XCTAssertEqual(code.filter { $0.contains("RealtimeProviderPreference.set(") }.count, 0)
    }

    // MARK: - Backstep

    /// Backing into or past `voice` keeps the voice choice: it is not in
    /// `Entry`, and entering `.voice` discards nothing from the record.
    func testEnteringVoiceDiscardsNothing() {
        var c = Commission()
        c.callsign = "ATLAS"
        c.nodeEnrolled = true
        let start = Backstep.Entry(commission: c, scanning: false, authed: true)
        XCTAssertEqual(Backstep.entering(.voice, from: start), start)
    }

    func testBackwardWalkThroughVoiceKeepsTheVoiceChoice() {
        RealtimeProviderPreference.set("openai", defaults)
        let state = VoiceProviderState.choices([choice("openai", keyed: true)])
        var step: CommissioningStep = .callsign
        var entry = Backstep.Entry(commission: Commission(), scanning: false, authed: true)
        var visitedVoice = false
        while let prev = Backstep.previous(of: step) {
            entry = Backstep.entering(prev, from: entry)
            if prev == .voice { visitedVoice = true }
            step = prev
        }
        XCTAssertTrue(visitedVoice, "VOID: the walk never entered .voice")
        XCTAssertEqual(RealtimeProviderPreference.resolved(in: state, defaults)?.id, "openai")
    }

    // MARK: - Forward label

    func testForwardSaysSkipUntilAChoiceResolves() {
        let state = VoiceProviderState.choices([choice("openai", keyed: true)])
        XCTAssertEqual(VoiceStep.forwardTitle(state, defaults), VoiceStep.skipTitle)
        RealtimeProviderPreference.set("openai", defaults)
        XCTAssertEqual(VoiceStep.forwardTitle(state, defaults), VoiceStep.continueTitle)
        XCTAssertNotEqual(VoiceStep.skipTitle, VoiceStep.continueTitle)
    }

    func testAStoredChoiceWithoutAKeyStillSaysSkip() {
        RealtimeProviderPreference.set("openai", defaults)
        let state = VoiceProviderState.choices([choice("openai", keyed: false)])
        XCTAssertEqual(VoiceStep.forwardTitle(state, defaults), VoiceStep.skipTitle)
    }

    /// Nothing to pick: the step must still be leavable, and not with SKIP
    /// wording for a choice the operator never had.
    func testNoRealtimeProviderStillOffersContinue() {
        XCTAssertEqual(VoiceStep.forwardTitle(.noRealtimeProvider, defaults), VoiceStep.continueTitle)
    }

    func testVoiceNarrationNamesTheSkip() {
        let line = CommissioningStep.voice.narration(commission: Commission())
        XCTAssertTrue(line.lowercased().contains("skip"))
        XCTAssertNotEqual(line, CommissioningStep.routes.narration(commission: Commission()))
    }
}
