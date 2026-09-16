import XCTest
@testable import Zeus

/// Phase 2 — the ZEUS-tab agent surface.
///
/// Three claims, and the third is the one with a defect behind it:
///
/// 1. the orb meters REAL audio while the tap is installed, and falls back to
///    the two-valued constant when nothing is metering;
/// 2. the ROUTE pill reads the live catalogue, never a transcribed provider
///    list carrying invented latencies;
/// 3. BROADCAST and PING are TERMINALLY disabled, on VERB ABSENCE — not on
///    link state.
///
/// APERTURE, STATED. `HomeView` has no in-process observable: a SwiftUI body
/// cannot be rendered and read back from this target. So the shape is the one
/// `NodeRowSourceTests` already uses — every pure derivation is proved over
/// its whole domain behaviourally, and a SOURCE SLICE proves the view calls it
/// rather than a literal. Neither half alone is the claim. A leg asserting
/// only that a derivation is correct is a property of the TYPE and stays green
/// with the body still passing the old constant: that is the exact shape that
/// let `icon: "doc"` survive a green suite in S5, and this is the fourth
/// arrival of that class (S3a `SessionRow`, S3b private method, S5 `icon`,
/// Phase 1 tap wiring).
@MainActor
final class HomeControlsTests: XCTestCase {

    // MARK: - 1 · the orb reads real audio while the tap is installed

    /// PRE-REGISTERED VACUOUS FORM, named first so it cannot be written later
    /// by accident: "`orbLevel` accepts a mic level" passes on an
    /// implementation that ignores the argument entirely. The discriminating
    /// form is that DIFFERENT mic levels produce DIFFERENT results while
    /// `.listening`, and the SAME result regardless of mic level otherwise.
    func testTheOrbMetersRealAudioOnlyWhileTheTapIsInstalled() {
        let quiet = HomeView.orbLevel(for: .listening, voiceState: .listening, micLevel: 0.11)
        let loud  = HomeView.orbLevel(for: .listening, voiceState: .listening, micLevel: 0.84)
        XCTAssertEqual(quiet, 0.11, accuracy: 0.0001)
        XCTAssertEqual(loud, 0.84, accuracy: 0.0001)
        XCTAssertNotEqual(quiet, loud,
                          "the listening arm must vary with the meter, not with the phase")

        for state in [VoiceState.idle, .denied, .unavailable] {
            XCTAssertEqual(
                HomeView.orbLevel(for: .ambient, voiceState: state, micLevel: 0.9),
                0.2,
                "\(state) installs no tap — a mic value here is a fabricated measurement"
            )
        }
    }

    /// `DeviceOrb.level` is documented `0...1` (`DeviceOrb.swift:69`). A
    /// renderer argument may not inherit a producer's range by assumption, so
    /// the clamp lives at the seam that hands the value over.
    func testTheMeteredArmIsClampedAtTheSeam() {
        XCTAssertEqual(HomeView.orbLevel(for: .listening, voiceState: .listening, micLevel: 3.0), 1.0)
        XCTAssertEqual(HomeView.orbLevel(for: .listening, voiceState: .listening, micLevel: -2.0), 0.0)
    }

    // MARK: - 2 · ROUTE reads the catalogue

    /// Selection wins; otherwise the catalogue's own word for why it is empty;
    /// otherwise the invitation. Every arm enumerated.
    func testTheRoutePillReadsTheCatalogueAcrossEveryArm() {
        let route = Route(id: "anthropic", name: "Anthropic", tagline: "", reach: .direct)
        XCTAssertEqual(
            HomeView.routeValue(selected: route,
                                state: .loaded(routes: [route], activeModel: nil)),
            Theme.joined(["ROUTE", "ANTHROPIC"])
        )
        XCTAssertEqual(
            HomeView.routeValue(selected: nil, state: .unconfigured("no gateway configured")),
            Theme.joined(["ROUTE", "NO GATEWAY CONFIGURED"]),
            "an unconfigured catalogue says so — it does not name a provider nothing enumerated"
        )
        XCTAssertEqual(
            HomeView.routeValue(selected: nil, state: .unavailable(reason: "gateway refused")),
            Theme.joined(["ROUTE", "GATEWAY REFUSED"])
        )
        XCTAssertEqual(
            HomeView.routeValue(selected: nil, state: .loaded(routes: [], activeModel: nil)),
            Theme.joined(["ROUTE", "GATEWAY ENUMERATES NO PROVIDERS"])
        )
        XCTAssertEqual(
            HomeView.routeValue(selected: nil, state: .loading),
            Theme.joined(["ROUTE", "TAP TO SELECT"]),
            "loading has no emptyReason; the pill invites rather than inventing one"
        )
    }

    /// The prototype ships eight hardcoded routes carrying invented
    /// `P50 180MS` latencies. NEG: none of that vocabulary reaches this
    /// screen. A fabricated number in a telemetry-shaped slot is the
    /// `t-12min` defect wearing a catalogue.
    func testNoInventedCatalogueOrLatencyReachesTheHomeScreen() throws {
        let code = Self.codeOnly(try Self.homeViewSource()).uppercased()
        for literal in ["P50 ", "180MS", "MAVERICK", "GPT-5", "GEMINI 3", "PROVIDERS ENROLLED"] {
            XCTAssertFalse(code.contains(literal),
                           "NEG: \(literal) is a transcribed prototype literal, not a fetched value")
        }
        XCTAssertTrue(code.contains("ROUTES.SELECTED"),
                      "POS: the pill reads the live catalogue store")
    }

    // MARK: - 3 · BROADCAST / PING — terminal disable on VERB ABSENCE

    /// The census, RE-DERIVED AT RUN TIME rather than cited in a comment: an
    /// emitted coordinate the instrument cannot re-derive is a comment wearing
    /// an assertion's clothes.
    ///
    /// POS control (`sessions`, a verb that exists) and NEG control
    /// (`zzzNoSuchVerb`, which cannot) run in the SAME invocation, so a zero
    /// on the subject is a PROVEN absence rather than a broken search.
    func testTheNodeVerbsAreAbsentFromEveryReachableSurface() throws {
        let sources = Self.codeOnly(try Self.allSourceText())

        XCTAssertGreaterThan(Self.count(of: "sessions", in: sources), 10,
                             "POS control: a verb that exists must be found")
        XCTAssertEqual(Self.count(of: "zzzNoSuchVerb", in: sources), 0,
                       "NEG control: a name that cannot exist must not be found")

        for verb in ["broadcastToNode", "pingNode", "chimeNode", "wakeNode", "restartNode"] {
            XCTAssertEqual(Self.count(of: verb, in: sources), 0,
                           "\(verb) now exists — the terminal disable is no longer the honest arm, "
                           + "and these two controls must be wired instead of refused")
        }
    }

    /// The disabled reason names the MISSING VERB and makes no transport claim.
    func testTheAbsentVerbLabelClaimsNoTransport() {
        let broadcast = HomeView.absentVerbLabel(control: "Broadcast")
        let ping = HomeView.absentVerbLabel(control: "Ping node")
        for label in [broadcast, ping] {
            let lower = label.lowercased()
            for claim in ["sent", "queued", "chimed", "delivered", "reached"] {
                XCTAssertFalse(lower.contains(claim),
                               "NEG: '\(claim)' asserts something left the phone")
            }
            XCTAssertTrue(lower.contains("no transport"),
                          "POS: the reason must name the absence")
        }
        XCTAssertNotEqual(broadcast, ping,
                          "two controls, two labels — one shared string makes them "
                          + "indistinguishable to a non-sighted operator")
    }

    /// The row note prefers the FIXABLE problem: a denied mic can be resolved
    /// in Settings, and outranks a note about two controls that can never work.
    func testTheControlsNotePrefersTheFixableProblem() throws {
        XCTAssertEqual(HomeView.controlsNote(voiceState: .denied), VoiceState.denied.line)
        XCTAssertEqual(HomeView.controlsNote(voiceState: .listening), VoiceState.listening.line)

        let idle = try XCTUnwrap(HomeView.controlsNote(voiceState: .idle))
        // Composed, not transcribed: `Theme.separator` is NBSP-padded
        // (`\u{00A0}·\u{00A0}`), so a literal typed with ordinary spaces
        // compares unequal to a string that is byte-for-byte correct. A test
        // that re-implements its subject's separator tests the typist.
        XCTAssertEqual(idle, Theme.joined(["BROADCAST",
                                           "PING — NO NODE TRANSPORT ON THIS BUILD"]))
        XCTAssertFalse(idle.lowercased().contains("unreachable"),
                       "NEG: unreachable is a LINK claim — the defect here is an absent verb, "
                       + "and the two are not the same fact")
    }

    /// COMMS reports the mic's state rather than always claiming a mic — the
    /// rule `SessionView:488` already applies, reused so two screens cannot
    /// draw different pictures of one `VoiceInput`.
    func testTheCommsGlyphAndLabelReportTheMicState() {
        XCTAssertEqual(HomeView.commsSymbol(for: .idle), "mic")
        XCTAssertEqual(HomeView.commsSymbol(for: .listening), "stop.fill")
        XCTAssertEqual(HomeView.commsSymbol(for: .denied), "mic.slash")
        XCTAssertEqual(HomeView.commsSymbol(for: .unavailable), "mic.slash")

        let labels = Set([VoiceState.idle, .listening, .denied, .unavailable]
                            .map { HomeView.commsLabel(for: $0) })
        XCTAssertEqual(labels.count, 4,
                       "four states, four labels: a shared label makes three of them "
                       + "indistinguishable without sight")
    }

    // MARK: - Source slices — the VIEW reads these, not just the type

    /// Slices the shipped `agent` body and asserts the metered derivation is
    /// reached inside it. VOID if either anchor moves.
    func testTheOrbBodyPassesTheMeteredDerivation() throws {
        let slice = try Self.slice(of: Self.homeViewSource(),
                                   from: "private var agent: some View {",
                                   to: ".accessibilityValue(DeviceOrb.accessibilityValue")
        XCTAssertTrue(slice.contains("Self.orbLevel(for: session.state"),
                      "POS: the orb body calls the derivation")
        XCTAssertTrue(slice.contains("voiceState: voiceState"),
                      "the body must hand the MIC STATE in — without it the metered arm "
                      + "is unreachable and the orb is back on a constant")
        XCTAssertTrue(slice.contains("micLevel: voiceLevel"),
                      "the body must hand the LIVE METER in")
        XCTAssertFalse(slice.contains("zzzNoSuchSymbol"),
                       "NEG control: the slice did not escape its anchors")
    }

    /// COMMS is wired to the one `VoiceInput`; the other two are disabled
    /// UNCONDITIONALLY.
    ///
    /// The second half is load-bearing. `LinkMonitor` IS in scope in this view
    /// (`HomeView:24`) with `LinkState.unreachable(host:reason:)` available, so
    /// conditioning these controls on link state costs nothing and is a live
    /// temptation — and it would ASSERT THE VERB EXISTS and is merely
    /// unreachable. It does not exist. A missing verb is terminal, exactly as
    /// `VoiceState.unavailable` is terminal (`Voice.swift:117`/`:139`); an
    /// unreachable host is not.
    func testTheControlsRowWiresCommsAndDisablesTheRestUnconditionally() throws {
        let slice = try Self.slice(of: Self.homeViewSource(),
                                   from: "private var agentControls: some View {",
                                   to: "static let controlSide")
        XCTAssertTrue(slice.contains("action: onVoice"),
                      "POS: COMMS runs the one VoiceInput's toggle")
        XCTAssertTrue(slice.contains("enabled: voiceState.isActionable"),
                      "COMMS arms on the mic's own actionability, not on a local flag")
        XCTAssertEqual(Self.count(of: "enabled: false", in: slice), 2,
                       "BROADCAST and PING must both be disabled by a LITERAL false")
        XCTAssertFalse(slice.contains("link."),
                       "NEG: no link-conditioned enablement — that asserts the verb exists "
                       + "and is merely unreachable, which is the costume defect one layer up")
        XCTAssertFalse(slice.contains("zzzNoSuchSymbol"),
                       "NEG control: the slice did not escape its anchors")
    }

    /// Nothing on this screen claims a node was reached.
    func testNoControlOnThisScreenClaimsSomethingLeftThePhone() throws {
        let code = try Self.homeViewSource().uppercased()
        for claim in ["BROADCAST SENT", "NODE CHIMED", "QUEUED FOR NEXT LINK"] {
            XCTAssertFalse(code.contains("SHOWTOAST(\"\(claim)"),
                           "NEG: '\(claim)' asserts a transport that does not exist")
        }
        XCTAssertTrue(code.contains("NO NODE TRANSPORT ON THIS BUILD"),
                      "POS: the honest reason is on the screen")
    }

    // MARK: - Helpers

    private static func count(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Source text with every `//` comment removed, line by line.
    ///
    /// WHY THIS EXISTS, and it cost five red legs to learn: a census that
    /// counts a name over raw source counts the name wherever it appears —
    /// INCLUDING inside the doc comment that explains why the name is absent.
    /// `HomeView` documents the verb census and the rejected `P50 180MS`
    /// literals in prose, so the raw-text instrument read its own subject's
    /// explanation as an occurrence and reported the defect it was written to
    /// refute. A census whose corpus includes prose cannot distinguish a use
    /// from a mention. Code is the corpus; comments are not code.
    ///
    /// Bounded deliberately: this strips line comments only. It does not
    /// parse strings, so a `//` inside a string literal is over-stripped —
    /// acceptable here because every leg's POS control is a CODE token, and a
    /// POS that survives the strip proves the strip did not eat the corpus.
    private static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex ..< slash.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relative)
    }

    private static func homeViewSource() throws -> String {
        try String(contentsOf: sourceURL("Sources/ZeusApp/HomeView.swift"), encoding: .utf8)
    }

    /// Every app + generated-FFI Swift source, concatenated — the corpus the
    /// verb census runs over. Asserts it loaded: an empty corpus would make
    /// every absence leg pass for the wrong reason.
    private static func allSourceText() throws -> String {
        let fm = FileManager.default
        var text = ""
        for dir in ["Sources/ZeusApp", "Sources/ZeusCoreFFI"] {
            guard let e = fm.enumerator(at: sourceURL(dir), includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertGreaterThan(text.count, 10_000, "VOID: the source corpus did not load")
        return text
    }

    private static func slice(of source: @autoclosure () throws -> String,
                              from open: String,
                              to close: String) throws -> String {
        let text = try source()
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound ..< text.endIndex)
        else {
            XCTFail("VOID — an anchor moved (\(open) … \(close)); this leg measured nothing")
            return ""
        }
        return String(text[start.upperBound ..< end.lowerBound])
    }
}
