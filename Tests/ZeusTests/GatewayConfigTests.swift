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
        XCTAssertEqual(GatewayConfig.resolve(from: [:]), .absent)
    }

    /// An empty string and whitespace are ABSENT, not malformed. Supplying
    /// `ZEUS_GATEWAY_URL=""` is how a shell spells "unset" by accident, and
    /// routing it to the malformed arm would name the wrong repair.
    func testBlankURLIsAbsentNotMalformed() {
        XCTAssertEqual(GatewayConfig.resolve(from: [k: ""]), .absent)
        XCTAssertEqual(GatewayConfig.resolve(from: [k: "   \n "]), .absent)
    }

    /// A token with no URL is still absent — the token is not a wire.
    func testTokenWithoutURLIsAbsent() {
        XCTAssertEqual(GatewayConfig.resolve(from: [t: "secret"]), .absent)
    }

    // MARK: - Malformed

    func testSchemelessIsRejected() {
        let got = GatewayConfig.resolve(from: [k: "192.168.1.100:8080"])
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
        let got = GatewayConfig.resolve(from: [k: "ftp://zeus.local:8080"])
        guard case let .malformed(_, reason) = got else {
            return XCTFail("expected malformed, got \(got)")
        }
        XCTAssertEqual(reason, .unsupportedScheme)
    }

    func testHostlessIsRejected() {
        let got = GatewayConfig.resolve(from: [k: "http:///path"])
        guard case let .malformed(_, reason) = got else {
            return XCTFail("expected malformed, got \(got)")
        }
        XCTAssertEqual(reason, .missingHost)
    }

    // MARK: - Resolved

    func testWellFormedResolves() {
        let got = GatewayConfig.resolve(from: [k: "http://192.168.1.100:8080"])
        guard case let .resolved(endpoint) = got else {
            return XCTFail("expected resolved, got \(got)")
        }
        XCTAssertEqual(endpoint.url.absoluteString, "http://192.168.1.100:8080")
        XCTAssertNil(endpoint.token)
    }

    func testHTTPSResolves() {
        guard case .resolved = GatewayConfig.resolve(from: [k: "https://zeus.example"]) else {
            return XCTFail("https must be accepted")
        }
    }

    func testTokenIsCarried() {
        let got = GatewayConfig.resolve(from: [k: "http://a.b", t: "sk-123"])
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
        let got = GatewayConfig.resolve(from: [k: "http://a.b", t: "   "])
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
        let summary = GatewayConfig.resolve(from: [k: "http://a.b", t: secret]).summary
        XCTAssertFalse(summary.contains(secret), "summary leaked the token")
        XCTAssertTrue(summary.contains("http://a.b"), "summary must still name the endpoint")
        XCTAssertTrue(summary.contains("token present"))
    }

    func testMalformedSummaryQuotesTheOperand() {
        let summary = GatewayConfig.resolve(from: [k: "ftp://x"]).summary
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
        let absent = await firstError(makeTransport(for: .absent))
        let malformed = await firstError(makeTransport(
            for: .malformed(raw: "ftp://x", reason: .unsupportedScheme)))

        XCTAssertNotEqual(absent, malformed)

        // Third arm: distinct by construction — a different type entirely.
        let resolved = makeTransport(for: GatewayConfig.resolve(from: [k: "http://a.b"]))
        XCTAssertTrue(resolved is HTTPTransport)
        XCTAssertFalse(makeTransport(for: .absent) is HTTPTransport)
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
        let absent = await firstError(makeTransport(for: .absent))
        let malformed = await firstError(makeTransport(
            for: .malformed(raw: "ftp://x", reason: .unsupportedScheme)))

        XCTAssertTrue(absent.contains("NO TRANSPORT"))
        XCTAssertFalse(malformed.contains("NO TRANSPORT"),
                       "a malformed config must not report the wire as absent")

        // The resolved arm is a real client — asserted by type, not by drain.
        XCTAssertTrue(
            makeTransport(for: GatewayConfig.resolve(from: [k: "http://a.b"])) is HTTPTransport,
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
            var yielded: [String] = []
            var threw = false
            do {
                for try await delta in makeTransport(for: config).stream(prompt: "p") {
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
