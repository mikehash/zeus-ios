import XCTest
@testable import Zeus

/// Config resolution legs.
///
/// `resolve(from:)` takes its environment as a parameter, so every leg here is
/// pure: no `setenv`, no process-global mutation, no ordering dependency
/// between tests. A test that mutates the process environment leaks into every
/// other test in the same process, and the leak is invisible until an unrelated
/// leg fails for a reason that has nothing to do with its subject.
final class GatewayConfigTests: XCTestCase {

    private let k = GatewayConfig.urlKey
    private let t = GatewayConfig.tokenKey

    // MARK: - Absent

    func testEmptyEnvironmentIsAbsent() {
        XCTAssertEqual(GatewayConfig.resolveFromEnvironment(from: [:]), .absent)
    }

    /// An empty string and whitespace are ABSENT, not malformed. Supplying
    /// `ZEUS_GATEWAY_URL=""` is how a shell spells "unset" by accident, and
    /// routing it to the malformed arm would name the wrong repair.
    func testBlankURLIsAbsentNotMalformed() {
        XCTAssertEqual(GatewayConfig.resolveFromEnvironment(from: [k: ""]), .absent)
        XCTAssertEqual(GatewayConfig.resolveFromEnvironment(from: [k: "   \n "]), .absent)
    }

    /// A token with no URL is still absent — the token is not a wire.
    func testTokenWithoutURLIsAbsent() {
        XCTAssertEqual(GatewayConfig.resolveFromEnvironment(from: [t: "secret"]), .absent)
    }

    // MARK: - Malformed

    func testSchemelessIsRejected() {
        let got = GatewayConfig.resolveFromEnvironment(from: [k: "192.168.1.100:8080"])
        guard case let .malformed(raw, reason) = got else {
            return XCTFail("expected malformed, got \(got)")
        }
        XCTAssertEqual(raw, "192.168.1.100:8080", "the operand must be carried verbatim")
        // 🔴 MEASURED, not assumed. I predicted `.unsupportedScheme` — reasoning
        // that `192.168.1.100:8080` parses with scheme "192.168.1.100" — and the
        // gate returned `.notAURL`: the RFC-3986 parser backing `URL(string:)`
        // on this SDK REFUSES it outright, because a scheme may not contain
        // digits in its first position. The intuition was from the older
        // lenient parser. The value below is what the toolchain does; the
        // comment records that the plausible answer was wrong.
        XCTAssertEqual(reason, .notAURL)
    }

    func testUnsupportedSchemeIsRejected() {
        let got = GatewayConfig.resolveFromEnvironment(from: [k: "ftp://zeus.local:8080"])
        guard case let .malformed(_, reason) = got else {
            return XCTFail("expected malformed, got \(got)")
        }
        XCTAssertEqual(reason, .unsupportedScheme)
    }

    func testHostlessIsRejected() {
        let got = GatewayConfig.resolveFromEnvironment(from: [k: "http:///path"])
        guard case let .malformed(_, reason) = got else {
            return XCTFail("expected malformed, got \(got)")
        }
        XCTAssertEqual(reason, .missingHost)
    }

    // MARK: - Resolved

    func testWellFormedResolves() {
        let got = GatewayConfig.resolveFromEnvironment(from: [k: "http://192.168.1.100:8080"])
        guard case let .resolved(endpoint) = got else {
            return XCTFail("expected resolved, got \(got)")
        }
        XCTAssertEqual(endpoint.url.absoluteString, "http://192.168.1.100:8080")
        XCTAssertNil(endpoint.token)
    }

    func testHTTPSResolves() {
        guard case .resolved = GatewayConfig.resolveFromEnvironment(from: [k: "https://zeus.example"]) else {
            return XCTFail("https must be accepted")
        }
    }

    func testTokenIsCarried() {
        let got = GatewayConfig.resolveFromEnvironment(from: [k: "http://a.b", t: "sk-123"])
        guard case let .resolved(endpoint) = got else {
            return XCTFail("expected resolved, got \(got)")
        }
        XCTAssertEqual(endpoint.token, "sk-123")
    }

    /// An empty token folds to nil rather than being sent as `Bearer `. A
    /// gateway rejecting an empty bearer answers 401, which reads as a WRONG
    /// token and sends the operator to rotate a credential that was never
    /// supplied — the wrong-subject failure this taxonomy exists to prevent.
    func testEmptyTokenFoldsToNil() {
        let got = GatewayConfig.resolveFromEnvironment(from: [k: "http://a.b", t: "   "])
        guard case let .resolved(endpoint) = got else {
            return XCTFail("expected resolved, got \(got)")
        }
        XCTAssertNil(endpoint.token)
    }

    // MARK: - Summary

    /// The summary is read by an operator, so it must never print the token.
    /// Asserted by absence of the secret AND presence of the endpoint — absence
    /// alone would pass on an empty string.
    func testSummaryNeverPrintsTheToken() {
        let secret = "sk-must-not-appear-9137"
        let summary = GatewayConfig.resolveFromEnvironment(from: [k: "http://a.b", t: secret]).summary
        XCTAssertFalse(summary.contains(secret), "summary leaked the token")
        XCTAssertTrue(summary.contains("http://a.b"), "summary must still name the endpoint")
        XCTAssertTrue(summary.contains("token present"))
    }

    func testMalformedSummaryQuotesTheOperand() {
        let summary = GatewayConfig.resolveFromEnvironment(from: [k: "ftp://x"]).summary
        XCTAssertTrue(summary.contains("ftp://x"), "summary must quote the rejected operand")
    }

    // MARK: - Transport selection

    /// The three arms must be DISTINGUISHABLE. Asserted pairwise-unequal
    /// rather than each-matches-a-string: a refactor that collapsed two arms
    /// into one message would still satisfy three separate `contains`
    /// assertions, and would not satisfy this.
    ///
    /// 🔴 CORRECTED AFTER THE WIRE LANDED. This leg used to drain all three
    /// transports. Once `.resolved` became a real `HTTPTransport`, the third
    /// drain opened a socket to `a.b` and the "error" it compared was a DNS
    /// failure — the leg still PASSED, for a reason that had nothing to do with
    /// config arms, and would have gone red on an airplane or green against a
    /// host that happened to resolve. A passing test whose subject has silently
    /// been replaced is worse than a failing one.
    ///
    /// The two unwired arms are still compared by MESSAGE; the wired arm is
    /// compared by TYPE, because its error is a property of a network rather
    /// than of this tree.
    func testThreeConfigArmsProduceDistinctErrors() async {
        let absent = await firstError(makeTransport(for: .absent, sessionID: SessionIDBox()))
        let malformed = await firstError(makeTransport(
            for: .malformed(raw: "ftp://x", reason: .unsupportedScheme),
            sessionID: SessionIDBox()))

        XCTAssertNotEqual(absent, malformed)

        // Third arm: distinct by construction — a different type entirely.
        let resolved = makeTransport(for: GatewayConfig.resolveFromEnvironment(from: [k: "http://a.b"]),
                          sessionID: SessionIDBox())
        XCTAssertTrue(resolved is HTTPTransport)
        XCTAssertFalse(makeTransport(for: .absent, sessionID: SessionIDBox()) is HTTPTransport)
    }

    /// The absent arm — and ONLY the absent arm — says NO TRANSPORT.
    ///
    /// HISTORY, kept because the drift is the point: this leg used to also
    /// assert the resolved arm said `"no HTTP client"`. That sentence was TRUE
    /// at `2596074a` and became FALSE the moment `HTTPTransport` landed, and
    /// this test is what caught it — it failed on the first gate after the cut
    /// rather than passing against a world that no longer existed. The claim is
    /// corrected here rather than deleted, because the *distinctness* it
    /// guards still matters: a resolved config must never report the wire as
    /// unconfigured, whatever the resolved arm goes on to do.
    ///
    /// The resolved arm is deliberately NOT drained here. It is now a real HTTP
    /// client, and draining it would open a socket — a unit test that performs
    /// network I/O fails for reasons that have nothing to do with its subject.
    /// Transport SELECTION is asserted structurally instead.
    func testOnlyAbsentSaysNoTransport() async {
        let absent = await firstError(makeTransport(for: .absent, sessionID: SessionIDBox()))
        let malformed = await firstError(makeTransport(
            for: .malformed(raw: "ftp://x", reason: .unsupportedScheme),
            sessionID: SessionIDBox()))

        XCTAssertTrue(absent.contains("NO TRANSPORT"))
        XCTAssertFalse(malformed.contains("NO TRANSPORT"),
                       "a malformed config must not report the wire as absent")

        // The resolved arm is a real client — asserted by type, not by drain.
        XCTAssertTrue(
            makeTransport(for: GatewayConfig.resolveFromEnvironment(from: [k: "http://a.b"]),
                          sessionID: SessionIDBox()) is HTTPTransport,
            "a resolved config must select the HTTP client")
    }

    /// The two NON-WIRED transports in this tree always fail and never yield.
    ///
    /// Scope narrowed from "every transport" when the wire landed: `.resolved`
    /// is excluded because it now reaches the network, and its behaviour is a
    /// property of a server rather than of this tree. The old name claimed a
    /// universal it can no longer measure — a claim whose subject has left the
    /// building is worse than no claim, because it reads as coverage.
    func testUnwiredTransportsNeverYieldAValue() async {
        for config: GatewayConfig in [
            .absent,
            .malformed(raw: "x", reason: .notAURL)
        ] {
            var yielded: [SessionFrame] = []
            var threw = false
            do {
                for try await delta in makeTransport(for: config, sessionID: SessionIDBox()).stream(prompt: "p") {
                    yielded.append(delta)
                }
            } catch {
                threw = true
            }
            XCTAssertTrue(yielded.isEmpty, "\(config) yielded \(yielded)")
            XCTAssertTrue(threw, "\(config) finished without throwing")
        }
    }

    // MARK: -

    /// Drains a transport and returns its terminating error description.
    /// Fails loudly rather than returning "" if the stream completes, so a
    /// silent success cannot pass as a distinct error string.
    private func firstError(_ transport: SessionTransport,
                            file: StaticString = #filePath,
                            line: UInt = #line) async -> String {
        do {
            for try await _ in transport.stream(prompt: "probe") {}
            XCTFail("transport completed without error", file: file, line: line)
            return "<no error>"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - The seam: resolve(from:store:)

/// Precedence legs for the two-source resolver.
///
/// One test per PRECEDENCE EDGE, not one per input: the defect this seam can
/// have is an ordering defect, and an ordering defect is only visible when
/// BOTH sources are populated at once. A suite that tests each source alone
/// would be fully green with the branches swapped.
final class GatewayResolutionTests: XCTestCase {

    private let k = GatewayConfig.urlKey
    private let t = GatewayConfig.tokenKey

    private func store(_ commission: Commission?) -> CommissionStoring {
        InMemoryCommissionStore(seed: commission)
    }

    private func commissioned(provider: String?) -> Commission {
        var c = Commission()
        c.provider = provider
        return c
    }

    // MARK: Edge 3 — neither source

    /// UNCHANGED BEHAVIOUR, restated through the new entry point. `.absent`
    /// keeps its meaning: nothing is listening. The twelve tests that stand on
    /// that meaning are untouched by this commit.
    func testNoEnvironmentAndNoCommissionIsAbsent() {
        let r = GatewayConfig.resolve(from: [:], store: store(nil))
        XCTAssertEqual(r.config, .absent)
        XCTAssertEqual(r.source, .unset)
    }

    // MARK: Edge 2 — commission alone

    /// THE PRODUCER THAT DID NOT EXIST. Before this commit no code path in the
    /// shipping app could return `.local`; it was reachable in tests and
    /// unreachable in the app. This leg is the whole point of the seam.
    func testCommissionWithProviderResolvesLocalReady() {
        let r = GatewayConfig.resolve(from: [:], store: store(commissioned(provider: "anthropic")))
        XCTAssertEqual(r.config, .local(.ready))
        XCTAssertEqual(r.source, .commission)
    }

    /// The third state, produced rather than constructed: a commission that
    /// never ran the routes step is LIVE and has no route to a model.
    func testCommissionWithoutProviderResolvesLocalNoProvider() {
        let r = GatewayConfig.resolve(from: [:], store: store(commissioned(provider: nil)))
        XCTAssertEqual(r.config, .local(.noProvider))
        XCTAssertEqual(r.source, .commission)
        XCTAssertEqual(r.config.disarmReason, GatewayConfig.noProviderMessage)
    }

    // MARK: Edge 1 — BOTH sources, the ordering leg

    /// THE MUTATION TARGET. Env wins over a persisted LOCAL choice, and the
    /// provenance says so. Swapping the two branches in `resolve(from:store:)`
    /// fails exactly here and nowhere else.
    func testEnvironmentBeatsCommission() {
        let r = GatewayConfig.resolve(
            from: [k: "https://gw.example.com"],
            store: store(commissioned(provider: "anthropic"))
        )
        XCTAssertEqual(
            r.config,
            .resolved(GatewayConfig.Endpoint(url: URL(string: "https://gw.example.com")!, token: nil))
        )
        XCTAssertEqual(r.source, .environment)
        // Vacuity guard: the two arms this test claims to distinguish must
        // actually differ. If `.local(.ready)` ever compares equal to the
        // resolved endpoint, the assertion above is satisfied by an identity
        // and proves nothing about ordering.
        XCTAssertNotEqual(r.config, .local(.ready))
    }

    /// A MALFORMED env value still beats the commission. Falling through to
    /// the persisted choice would repair the operator's typo behind his back
    /// and report success — the wrong-subject failure, one arm over.
    func testMalformedEnvironmentBeatsCommissionRatherThanFallingThrough() {
        let r = GatewayConfig.resolve(
            from: [k: "notaurl:::"],
            store: store(commissioned(provider: "anthropic"))
        )
        XCTAssertEqual(r.source, .environment)
        XCTAssertNotEqual(r.config, .local(.ready))
        guard case .malformed = r.config else {
            return XCTFail("expected .malformed, got \(r.config)")
        }
    }

    /// The token rides along with the env branch — the seam must not drop it
    /// while re-routing the return value through `Resolution`.
    func testEnvironmentTokenSurvivesTheSeam() {
        let r = GatewayConfig.resolve(
            from: [k: "https://gw.example.com", t: "sekret"],
            store: store(commissioned(provider: "anthropic"))
        )
        guard case let .resolved(endpoint) = r.config else {
            return XCTFail("expected .resolved, got \(r.config)")
        }
        XCTAssertEqual(endpoint.token, "sekret")
    }

    // MARK: - The no-default enumeration (②)

    /// Every `config`/`makeTransport`/`store` default is deleted, so the
    /// COMPILER enumerates the set of sites that must be handed a resolution.
    /// This leg guards the property the compiler cannot: that no site
    /// re-acquires one later.
    ///
    /// Shape: a CARDINALITY leg, not an absence leg. `GatewayConfig.resolve`
    /// must exist and must be CALLED, so "the string is absent" is
    /// unachievable. Two needles, each naming a defect that cannot be written
    /// any other way:
    ///
    /// 1. `: GatewayConfig =` — a DEFAULTED PARAMETER of config type. This is
    ///    the only syntax that can put resolution back into a parameter list,
    ///    which is the exact position where no store is in scope.
    /// 2. `resolveFromEnvironment` outside `GatewayConfig.swift` — the
    ///    env-only half leaking back out to a caller. It is `internal` by
    ///    necessity (the seam calls it), so visibility cannot enforce this.
    ///
    /// My first draft used `= GatewayConfig.resolve`, which failed on
    /// `RootView.swift:101` — the one legitimate call site, an ASSIGNMENT. A
    /// needle that cannot separate a default from an assignment is measuring
    /// the wrong subject; recorded because the failure was the instrument's,
    /// not the tree's.
    ///
    /// POS control in the same invocation: the declaration `static func
    /// resolve(` reads 1, so a wrong path VOIDs instead of falsely passing.
    func testNoProductionSiteDefaultsItsConfig() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp")

        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5,
                             "POS control: the directory scan found the sources")

        var defaulted: [String] = []
        var envOnlyLeaks: [String] = []
        var declarations = 0
        var configParameters = 0
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            let isSeamFile = f.lastPathComponent == "GatewayConfig.swift"
            for (n, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Comments describe the rule; only code can break it. (This
                // very test's docstring names both needles — the self-match
                // class, avoided by skipping comment lines rather than by
                // asking the docstring not to say what it guards.)
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.contains(": GatewayConfig =") {
                    defaulted.append("\(f.lastPathComponent):\(n + 1)")
                }
                if code.contains(": GatewayConfig") { configParameters += 1 }
                if !isSeamFile, code.contains("resolveFromEnvironment") {
                    envOnlyLeaks.append("\(f.lastPathComponent):\(n + 1)")
                }
                // Scoped to the SEAM FILE. This control counted every file
                // and read 2 the moment `RootView.resolve(store:)` was
                // extracted for MUT-C — a correct file failing a control that
                // measured a wider subject than it named. The control's claim
                // is "I am reading GatewayConfig.swift", so that is what it
                // counts.
                if isSeamFile, code.contains("static func resolve(") { declarations += 1 }
            }
        }

        XCTAssertEqual(declarations, 1,
                       "POS control: exactly one `static func resolve(` declaration was read")
        XCTAssertGreaterThan(configParameters, 3,
                             "POS control: config-typed properties/parameters exist to be defaulted")
        XCTAssertEqual(defaulted, [],
                       "a production site re-acquired a defaulted config: \(defaulted)")
        XCTAssertEqual(envOnlyLeaks, [],
                       "the env-only half leaked outside the seam: \(envOnlyLeaks)")
    }

    /// `AppState.store` must be readable by `RootView` — the seam is useless
    /// if the app cannot hand down the very store it was built with. Guards
    /// the visibility, which is the part a compile error would only surface
    /// at the one call site.
    func testAppStateExposesItsStoreReadOnly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/ZeusApp.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("final class AppState"),
                      "POS control: the grep is reading the right file")
        XCTAssertTrue(src.contains("let store: CommissionStoring"),
                      "the store must be exposed for RootView to pass down")
        XCTAssertFalse(src.contains("private let store: CommissionStoring"),
                       "read-only exposure, not private")
        XCTAssertFalse(src.contains("var store: CommissionStoring"),
                       "read-only: a second writer would mean two pictures of one commission")
    }

    /// The repair for MUT-C. `RootView.resolve(store:)` must HONOUR the store
    /// it is given — a fresh `UserDefaultsCommissionStore()` inside would read
    /// the phone's real defaults while the capture harness's seeded
    /// `InMemoryCommissionStore` says LOCAL, and every screenshot would be a
    /// lie with green legs. That is the precise failure Zeus100 ruled the
    /// no-default shape against, arriving one level below the parameter list.
    ///
    /// Vacuity guard: the seeded store and an empty one must resolve
    /// DIFFERENTLY, or this assertion is satisfied by an identity.
    func testRootViewResolutionHonoursTheInjectedStore() {
        let seeded = InMemoryCommissionStore()
        seeded.save(Commission(route: .byok, provider: "anthropic",
                               callsign: "TEST", nodeEnrolled: false))
        let empty = InMemoryCommissionStore()

        let fromSeeded = RootView.resolve(store: seeded)
        let fromEmpty = RootView.resolve(store: empty)

        XCTAssertNotEqual(fromSeeded.config, fromEmpty.config,
                          "vacuity guard: the two stores must resolve differently")
        XCTAssertEqual(fromSeeded.config, .local(.ready),
                       "the injected store's commission is the one that resolves")
        XCTAssertEqual(fromSeeded.source, .commission)
    }
}
