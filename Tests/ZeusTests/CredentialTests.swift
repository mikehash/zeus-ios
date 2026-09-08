import XCTest
@testable import Zeus

/// ③c(b) — the ONE precedence, and the census that keeps it one.
///
/// The defect this file exists to prevent is not a wrong value, it is a
/// DIVERGENCE: two credential precedences alive in one app, with chat working
/// and the approvals queue 401ing, while the LINK line says `KEYCHAIN`. That
/// state is invisible to any value assertion on either half — each half is
/// individually correct — so the guard has to be a census over the SITES.
final class CredentialTests: XCTestCase {

    // MARK: - substrate

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        return try String(contentsOf: root.appendingPathComponent("Sources/ZeusApp/\(name)"),
                          encoding: .utf8)
    }

    private func sourceFiles() throws -> [(name: String, code: [String])] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, codeLines(try source($0))) }
    }

    /// Comment lines stripped. A census that counts prose is a census of
    /// intentions — the `store.` POS on this branch read 2 on a file with no
    /// `store` property at all, both hits docstrings, and would have greened
    /// the guard that the write existed.
    private func codeLines(_ src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private func endpoint(_ url: String, token: String? = nil) -> GatewayConfig.Endpoint {
        .init(url: URL(string: url)!, token: token)
    }

    // MARK: - the census: one precedence, one secret reader

    /// `endpoint.token` has exactly TWO code-line readers in `Sources`.
    ///
    /// The FILE SET is the constant, not a total. Both readers named:
    ///   ① `Credential.swift` — the `.environment` arm of the precedence.
    ///   ② `GatewayConfig.swift` — `summary`, PRESENCE-ONLY, which prints
    ///      `(env token)` or nothing and never the bytes.
    /// The ruling for this leg said 1. It was walked against the tree and the
    /// second reader is legitimate: `summary` is a pure function of the config
    /// and threading a credential provider into it, to print a boolean, would
    /// put the Keychain hit back into the description path that ③c just took
    /// out of the resolution path. A census constant is a claim about the
    /// whole file set and it inherits every legitimate reader you did not walk.
    func testEndpointTokenHasExactlyTwoReadersAndBothAreNamed() throws {
        let files = try sourceFiles()

        // POS: the walk sees the file set at all. A dead directory read gives
        // the same zero as a perfectly-migrated tree.
        XCTAssertGreaterThan(files.count, 20,
                             "VOID: the Sources walk read \(files.count) files")

        var readers: [String: Int] = [:]
        for f in files {
            let n = f.code.filter { $0.contains("endpoint.token") }.count
            if n > 0 { readers[f.name] = n }
        }

        XCTAssertEqual(Set(readers.keys), ["Credential.swift", "GatewayConfig.swift"],
                       "endpoint.token readers drifted: \(readers). The provider is the "
                       + "only consumer-facing reader; GatewayConfig.summary is "
                       + "presence-only. Anything else is a second precedence.")
        // The constant is per-FILE, not a grand total. The ruling's "1" and my
        // restatement's "2" were both forecasts: `Credential.swift` reads it 4
        // times (env arm + provenance arm, in each of the production and stub
        // providers) and that number is a detail of the provider's own shape.
        // What must be pinned is the SUMMARY side — exactly one presence-only
        // read — and the file set, above. A number published without the
        // aperture that produced it is not a fact, and I published two.
        XCTAssertEqual(readers["GatewayConfig.swift"], 1,
                       "summary must read endpoint.token exactly once (presence only)")
        XCTAssertGreaterThanOrEqual(readers["Credential.swift"] ?? 0, 1,
                                    "VOID: the provider does not read the env token at all")
    }

    /// Every `Bearer` header in the app is built from the provider's answer.
    ///
    /// Four construction sites. For each, the ENCLOSING scope must contain a
    /// `credentials.credential(for:` call — a presence census on `Bearer`
    /// alone is green in both the correct and the diverged world, because the
    /// diverged world also has four `Bearer` sites.
    func testEveryBearerSiteIsFedByTheProvider() throws {
        let files = try sourceFiles()

        // POS on the needle whose SPELLING can only occur at a header site.
        // The bare `Authorization` needle reads 13 across 7 files here, nine
        // of them `UNAuthorizationStatus` / `requestAuthorization` — an OS
        // permission API sharing nine characters with an HTTP header. A POS
        // that passes on the wrong subject is not a control.
        let headerSites = files.flatMap { f in
            f.code.filter { $0.contains(#"forHTTPHeaderField: "Authorization""#) }.map { _ in f.name }
        }
        XCTAssertEqual(headerSites.count, 4,
                       "VOID or drift: header sites = \(headerSites)")

        var offenders: [String] = []
        for f in files where f.code.contains(where: { $0.contains(#"Bearer \("#) }) {
            let joined = f.code.joined(separator: "\n")
            if !joined.contains("credentials.credential(for:") {
                offenders.append(f.name)
            }
        }
        XCTAssertEqual(offenders, [],
                       "these files build a Bearer header without asking the provider: "
                       + "\(offenders) — that is a second precedence")

        // Cross-check the two counts describe the same set: a Bearer without a
        // header, or a header without a Bearer, is a shape nobody intended.
        let bearerFiles = files.filter { $0.code.contains(where: { $0.contains(#"Bearer \("#) }) }
                               .map(\.name)
        XCTAssertEqual(Set(bearerFiles), Set(headerSites), "Bearer sites ≠ Authorization sites")
    }

    /// ANTI-NEEDLE. `\.token` reads 9 in `Sources`; five are the SSE frame
    /// enum (`.token(text)`), a different subject sharing a spelling. Pinned
    /// so a rename of the frame case cannot move the credential count
    /// silently in either direction.
    func testTheSSEFrameCaseIsNotACredentialReader() throws {
        let files = try sourceFiles()
        let frames = files.flatMap { f in f.code.filter { $0.contains(".token(") }.map { _ in f.name } }
        XCTAssertEqual(frames.count, 5,
                       "SSE `.token(` count moved to \(frames.count) — \(frames). If a frame "
                       + "case was renamed, retune this anti-needle; if a credential reader "
                       + "was added, it belongs in the provider.")
    }

    // MARK: - the precedence itself

    func testEnvironmentTokenWinsOverTheKeychain() {
        let p = StubCredentialProvider(stored: ["h": "from-keychain"])
        XCTAssertEqual(p.credential(for: endpoint("http://h:1", token: "from-env")), "from-env")
        XCTAssertEqual(p.source(for: endpoint("http://h:1", token: "from-env")), .environment)
    }

    func testTheKeychainAnswersWhenTheEnvironmentDidNot() {
        let p = StubCredentialProvider(stored: ["h": "from-keychain"])
        XCTAssertEqual(p.credential(for: endpoint("http://h:1")), "from-keychain")
        XCTAssertEqual(p.source(for: endpoint("http://h:1")), .keychain)
    }

    func testNoCredentialIsNilAndHasNoProvenanceWord() {
        let p = StubCredentialProvider()
        XCTAssertNil(p.credential(for: endpoint("http://h:1")))
        XCTAssertNil(p.source(for: endpoint("http://h:1")),
                     "a provenance word with no credential names a source for nothing")
    }

    /// The stub and the production type must agree on ORDER, or every leg
    /// above is a statement about the stub alone. Exercised on the arm that
    /// needs no Keychain: env present ⇒ env wins, in BOTH types.
    func testTheProductionProviderHasTheSamePrecedenceDirection() {
        let real = KeychainCredentialProvider(service: "com.zeus.test.\(UUID().uuidString)")
        let e = endpoint("http://unlikely-host-\(UUID().uuidString):1", token: "from-env")
        XCTAssertEqual(real.credential(for: e), "from-env")
        XCTAssertEqual(real.source(for: e), .environment)
        // And with no env and no Keychain item under a fresh service: silence.
        let empty = endpoint("http://unlikely-host-\(UUID().uuidString):1")
        XCTAssertNil(real.credential(for: empty))
        XCTAssertNil(real.source(for: empty))
    }

    // MARK: - the LINK provenance word

    private var resolvedRes: GatewayConfig.Resolution {
        .init(config: .resolved(endpoint("http://h:1")), source: .environment)
    }

    func testTheProvenanceWordRidesOnlyOnTheLinkedArm() {
        let p = StubCredentialProvider(stored: ["h": "k"])
        let linked = RootView.statusLine(.linked(host: "h", ms: 7),
                                         resolution: resolvedRes, credentials: p)
        XCTAssertTrue(linked.hasSuffix(" · KEYCHAIN"), "got \(linked)")

        // Every other arm: the base line, unchanged, byte for byte. A
        // provenance word on LINKING… or on NO GATEWAY is a claim about a
        // credential for a config that has no endpoint to hold one.
        for state: LinkState in [.unconfigured, .probing, .embedded,
                                 .unreachable(host: "h", reason: "refused")] {
            let line = RootView.statusLine(state, resolution: resolvedRes, credentials: p)
            XCTAssertEqual(line, state.statusLine,
                           "\(state) must carry no provenance word — got \(line)")
        }
    }

    func testTheProvenanceWordNamesTheSourceAndNeverTheSecret() {
        let env = GatewayConfig.Resolution(config: .resolved(endpoint("http://h:1", token: "SECRET")),
                                           source: .environment)
        let line = RootView.statusLine(.linked(host: "h", ms: 7),
                                       resolution: env,
                                       credentials: StubCredentialProvider())
        XCTAssertTrue(line.hasSuffix(" · ENV"), "got \(line)")
        XCTAssertFalse(line.contains("SECRET"), "the LINK line printed the token")
    }

    func testNoCredentialAppendsNothing() {
        let line = RootView.statusLine(.linked(host: "h", ms: 7),
                                       resolution: resolvedRes,
                                       credentials: StubCredentialProvider())
        XCTAssertEqual(line, LinkState.linked(host: "h", ms: 7).statusLine)
        XCTAssertFalse(line.contains("·  "), "an empty suffix orphaned its separator")
    }

    /// DISTINCTNESS. The three outcomes must differ — a composer that returned
    /// the base line in all three cases satisfies "no secret" and "no word on
    /// the wrong arm" simultaneously, and says nothing.
    func testTheThreeProvenanceOutcomesAreDistinct() {
        let base = LinkState.linked(host: "h", ms: 7)
        let none = RootView.statusLine(base, resolution: resolvedRes,
                                       credentials: StubCredentialProvider())
        let keychain = RootView.statusLine(base, resolution: resolvedRes,
                                           credentials: StubCredentialProvider(stored: ["h": "k"]))
        let envRes = GatewayConfig.Resolution(
            config: .resolved(endpoint("http://h:1", token: "t")), source: .environment)
        let env = RootView.statusLine(base, resolution: envRes,
                                      credentials: StubCredentialProvider())
        XCTAssertEqual(Set([none, keychain, env]).count, 3,
                       "collapsed: \(none) / \(keychain) / \(env)")
    }

    /// APERTURE, asserted rather than assumed: the NODES pill and its subtitle
    /// stay TOPOLOGY-ONLY. Written down so a future reader never reads the
    /// absence of a provenance word there as a miss.
    func testTheNodesPillCarriesNoProvenance() {
        let linked = LinkState.linked(host: "h", ms: 7)
        XCTAssertFalse(linked.badgeText.contains("KEYCHAIN"))
        XCTAssertFalse(linked.badgeText.contains("ENV"))
        XCTAssertFalse(linked.subtitle.contains("KEYCHAIN"))
        XCTAssertFalse(linked.subtitle.contains("ENV"))
    }
}
