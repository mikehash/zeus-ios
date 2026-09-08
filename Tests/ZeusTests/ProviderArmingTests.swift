import XCTest
@testable import Zeus

/// Readiness measured on the CORE, and the one production call that arms it.
///
/// THE INCIDENT: `GatewayConfig.resolve` derived `.local(.ready)` from
/// `commission.provider == nil`. That is a string on disk. The core's client
/// `Option` was `None` for the life of the process because `Sources/ZeusApp`
/// contained zero `setProvider` callers, so the console said READY and every
/// send returned `NoProvider`. `testAnUnarmedCoreIsNotReadyEvenWithAProvider`
/// is that incident: it FAILS against the pre-cut resolver.
final class ProviderArmingTests: XCTestCase {

    // MARK: - Doubles

    /// A core whose arm state is settable, so both arms of readiness are
    /// reachable. `armed` is `var` because a double fixed at one value can
    /// only ever test one branch, and a one-branch readiness test passes
    /// against a constant.
    private final class ArmingCore: ZeusCoreProtocol {
        var armed = false
        var models: [String] = []
        var listThrows = false
        var setThrows = false
        private(set) var setCalls: [(id: String, model: String, key: String, baseUrl: String?)] = []

        func hasProvider() -> Bool { armed }

        func setProvider(id: String, model: String, key: String, baseUrl: String?) throws {
            setCalls.append((id, model, key, baseUrl))
            if setThrows { throw NSError(domain: "test", code: 1) }
            armed = true
        }

        func listModels(id: String, key: String, baseUrl: String?) throws -> [String] {
            if listThrows { throw NSError(domain: "test", code: 2) }
            return models
        }

        // The rest of the surface, unimplemented on purpose: this double's
        // subject is arming. A send that returned fixture text would let a
        // readiness leg pass through a core that cannot send.
        func indexSize() -> UInt32 { 0 }
        func send(sessionId: String, text: String, sink: TokenSink) throws {}
        func sessions() throws -> [SessionInfo] { [] }
        func remember(fact: String) throws {}
        func search(query: String) -> [SearchHit] { [] }
    }

    private struct FixedArming: ProviderArming {
        let isArmed: Bool
    }

    private func commissioned(provider: String?, model: String?) -> Commission {
        Commission(route: .byok,
                   provider: provider,
                   callsign: "test",
                   nodeEnrolled: false,
                   deployment: .local,
                   gatewayURL: nil,
                   model: model)
    }

    private func localResolution(_ c: Commission) -> GatewayConfig.Resolution {
        GatewayConfig.resolve(from: [:], store: InMemoryCommissionStore(seed: c))
    }

    // MARK: - The incident

    /// THE LEG THE PRE-CUT CODE FAILS. Commission names a provider; the core
    /// is unarmed. Readiness must be `.noProvider`.
    func testAnUnarmedCoreIsNotReadyEvenWithAProvider() {
        let base = localResolution(commissioned(provider: "anthropic", model: "claude"))
        XCTAssertEqual(base.config, .local(.ready),
                       "PRECONDITION: the commission-only resolver still answers ready — if this changed, the leg below is measuring something else")

        let measured = base.withCoreReadiness(FixedArming(isArmed: false))
        XCTAssertEqual(measured.config, .local(.noProvider),
                       "a core with no provider must not render READY, however many provider strings sit on disk")
    }

    /// The other arm. Both are asserted, and asserted to DIFFER, because a
    /// hardcoded readiness passes whichever single arm a test names.
    func testAnArmedCoreIsReady() {
        let base = localResolution(commissioned(provider: "anthropic", model: "claude"))
        let armed = base.withCoreReadiness(FixedArming(isArmed: true))
        let unarmed = base.withCoreReadiness(FixedArming(isArmed: false))

        XCTAssertEqual(armed.config, .local(.ready))
        XCTAssertNotEqual(armed.config, unarmed.config,
                          "readiness that does not move with the core's answer is a constant wearing a function's name")
    }

    /// Remote arms are NOT the local core's subject and must pass through.
    func testRemoteResolutionsAreUntouchedByCoreReadiness() {
        var c = commissioned(provider: "anthropic", model: "claude")
        c.deployment = .remote
        c.gatewayURL = "https://gw.example.com"
        let base = localResolution(c)
        guard case .resolved = base.config else {
            return XCTFail("VOID: fixture did not produce a resolved remote config — got \(base.config)")
        }
        XCTAssertEqual(base.withCoreReadiness(FixedArming(isArmed: false)).config, base.config,
                       "a remote gateway's readiness is not this process's core to answer")
    }

    // MARK: - Arming

    func testArmPassesTheCommissionProviderAndModelToTheCore() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "anthropic", model: "claude-x"),
                                    core: core,
                                    providerKey: "sk-real",
                                    baseURL: nil)
        XCTAssertNil(reason, "arming with a provider, a model and a key must succeed")
        XCTAssertEqual(core.setCalls.count, 1)
        XCTAssertEqual(core.setCalls.first?.id, "anthropic")
        XCTAssertEqual(core.setCalls.first?.model, "claude-x")
        XCTAssertEqual(core.setCalls.first?.key, "sk-real")
        XCTAssertTrue(core.hasProvider())
    }

    /// THE URL LEG. Ollama's host is resolved inside the core from
    /// `OLLAMA_HOST`; the base URL is the only way iOS can name it, and it
    /// must reach `setProvider` unaltered.
    func testTheOllamaBaseURLReachesTheCore() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "ollama", model: "llama3.2"),
                                    core: core,
                                    providerKey: nil,
                                    baseURL: "http://127.0.0.1:11434")
        XCTAssertNil(reason)
        XCTAssertEqual(core.setCalls.first?.baseUrl, "http://127.0.0.1:11434",
                       "a base URL the app drops leaves the core resolving OLLAMA_HOST on a phone that has no ollama")
    }

    /// Ollama takes the placeholder, NOT an empty string: the core rejects
    /// `""` (zeus-llm:1376-1384) and would name the wrong cause.
    func testTheKeylessProviderSendsThePlaceholderNotAnEmptyKey() {
        let core = ArmingCore()
        _ = CoreArming.arm(commission: commissioned(provider: "ollama", model: "llama3.2"),
                           core: core,
                           providerKey: nil,
                           baseURL: nil)
        XCTAssertEqual(core.setCalls.first?.key, CoreArming.ollamaKeyPlaceholder)
        XCTAssertFalse(CoreArming.ollamaKeyPlaceholder.isEmpty,
                       "an empty key is refused by the core with an error naming the header, not the key")
    }

    /// UNARMED ≠ UNREACHABLE — two distinct strings, an equality leg on each.
    /// A single "something went wrong" for both is how an operator restarts
    /// the app to fix a daemon that is not running.
    func testUnarmedAndUnreachableAreDifferentStrings() {
        let noProvider = CoreArming.arm(commission: commissioned(provider: nil, model: nil),
                                        core: ArmingCore(),
                                        providerKey: nil,
                                        baseURL: nil)
        XCTAssertEqual(noProvider, GatewayConfig.noProviderMessage)

        let refusing = ArmingCore()
        refusing.setThrows = true
        let refused = CoreArming.arm(commission: commissioned(provider: "ollama", model: "llama3.2"),
                                     core: refusing,
                                     providerKey: nil,
                                     baseURL: nil)
        XCTAssertNotNil(refused)
        XCTAssertNotEqual(refused, GatewayConfig.noProviderMessage,
                          "a provider that refused the call is not a provider nobody chose")
        XCTAssertTrue(refused?.contains("REFUSED") == true, "got \(refused ?? "nil")")
    }

    func testAMissingModelIsNamedNotGuessed() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "anthropic", model: nil),
                                    core: core,
                                    providerKey: "sk-real",
                                    baseURL: nil)
        XCTAssertEqual(reason, "NO MODEL — Anthropic LISTED NONE")
        XCTAssertTrue(core.setCalls.isEmpty,
                      "a model the app invented is a model no provider serves — the call must not be made")
    }

    func testAKeyedProviderWithoutAKeyIsNamed() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "anthropic", model: "claude"),
                                    core: core,
                                    providerKey: nil,
                                    baseURL: nil)
        XCTAssertEqual(reason, "NO KEY FOR Anthropic — ENTER ONE IN ROUTES")
        XCTAssertTrue(core.setCalls.isEmpty)
    }

    // MARK: - The model comes from the provider

    func testFirstModelReturnsTheProvidersFirstEntry() {
        let core = ArmingCore()
        core.models = ["llama3.2:latest", "qwen3.8:27b-mlx"]
        XCTAssertEqual(CoreArming.firstModel(for: "ollama", core: core, key: nil, baseURL: nil),
                       "llama3.2:latest")
    }

    /// v1's `list_models` is Ollama-only. A provider that cannot answer must
    /// yield nil, NOT a fabricated model name.
    func testAProviderThatCannotListYieldsNil() {
        let core = ArmingCore()
        core.listThrows = true
        XCTAssertNil(CoreArming.firstModel(for: "anthropic", core: core, key: "sk", baseURL: nil))
    }

    func testRecordRoutesChoiceStoresTheProvidersModel() {
        var c = Commission()
        c.recordRoutesChoice(providerID: "ollama", model: "llama3.2:latest")
        XCTAssertEqual(c.provider, "ollama")
        XCTAssertEqual(c.model, "llama3.2:latest")

        var none = Commission()
        none.recordRoutesChoice(providerID: "anthropic", model: nil)
        XCTAssertNil(none.model, "nil is the provider's answer, stored as such")
    }

    /// MIGRATION: a record written before `model` existed must still decode.
    func testALegacyRecordWithoutAModelStillDecodes() throws {
        let legacy = #"{"route":"byok","provider":"anthropic","callsign":"x","node_enrolled":false}"#
        let c = try JSONDecoder().decode(Commission.self, from: Data(legacy.utf8))
        XCTAssertNil(c.model)
        XCTAssertEqual(c.provider, "anthropic")
    }

    // MARK: - The census

    /// THE PRODUCTION CALLER EXISTS, IS SINGULAR, AND IS NOT DEBUG-ONLY.
    ///
    /// A source census, which is the weaker instrument — stated. The strong
    /// legs above prove `CoreArming.arm` behaves; only this one proves the app
    /// calls it, because `RootView.init` is a SwiftUI initialiser with no
    /// observable seam. MUT: delete the call in `RootView.init` and this leg
    /// fails alone.
    func testTheProductionPathComposesCoreReadiness() throws {
        let root = try sourceFile("RootView.swift")

        // POS control in the same invocation: a string known present.
        XCTAssertTrue(root.contains("init(store: CommissionStoring"),
                      "VOID: the needle is dead — RootView.swift did not contain its own initialiser")

        let armCalls = occurrences(of: "CoreArming.arm(", in: root)
        XCTAssertEqual(armCalls, 1,
                       "expected exactly one production arming call in RootView; found \(armCalls)")
        XCTAssertTrue(root.contains(".withCoreReadiness("),
                      "readiness must be re-derived from the core; without this the resolver's disk answer is what renders")
        // NOT `root.contains("#if DEBUG")` — that read the file, not the CALL.
        // RootView holds unrelated DEBUG blocks, so the broad needle failed a
        // correct file: a census must be scoped to its SUBJECT's line.
        XCTAssertFalse(isInsideDebugBlock(needle: "CoreArming.arm(", in: root),
                       "the production arming path must not be inside a DEBUG block")
    }

    /// THE SAVE PATH KEEPS THE CORE'S ANSWER.
    ///
    /// The incident: at `a06bbe4` the composition lived in `init` only, and
    /// the editor's `onSaved` re-resolve called `RootView.resolve(store:)`
    /// bare — so one gateway SAVE reverted the `.local` readiness arm to
    /// `commission.provider == nil`, the disk-derived value the commit
    /// existed to retire. `GatewayConfigSource.adopt` is the sole writer of
    /// `resolution`, so nothing downstream could observe the revert.
    ///
    /// Aperture, stated: this is a SOURCE CENSUS, weaker than a type change.
    /// It asserts that every production entry point routes through the one
    /// helper, not that the helper is correct — the behavioural legs above
    /// (`testAnUnarmedCoreIsNotReadyEvenWithAProvider`, `testAnArmedCoreIsReady`)
    /// are what measure the helper itself.
    func testEveryProductionEntryPointResolvesThroughTheArmedHelper() throws {
        let root = try sourceFile("RootView.swift")
        let lines = root.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }

        // POS control, same invocation: a call form known present.
        XCTAssertEqual(lines.filter { $0.contains("armedResolution(store: store, keys: keys)") }.count, 2,
                       "VOID or drift: expected exactly two entry points (init + onSaved) into the armed helper")

        // The bare resolver may appear ONLY inside the helper — one call, and
        // it is the one the helper composes onto.
        let bare = lines.filter { $0.contains("RootView.resolve(store: store)") }
        XCTAssertEqual(bare.count, 1,
                       "a bare `RootView.resolve` outside the helper drops the core's readiness answer; found \(bare.count)")

        // And composition happens exactly once, in that same helper.
        XCTAssertEqual(occurrences(of: ".withCoreReadiness(", in: root), 1,
                       "readiness must be composed in ONE place; a second site is a second policy")
    }

    /// The bridge call itself has ONE production caller, in `ProviderArming`.
    func testSetProviderHasExactlyOneProductionCaller() throws {
        var total = 0
        var files: [String] = []
        for name in ["ProviderArming.swift", "RootView.swift", "Commissioning.swift",
                     "EmbeddedTransport.swift", "ZeusApp.swift", "LaunchArgs.swift",
                     "GatewayConfig.swift", "Session.swift"] {
            guard let body = try? sourceFile(name) else { continue }
            files.append(name)
            // ONE needle. Two overlapping needles double-counted the single
            // real call site and read 2 — a census that counts the same line
            // twice reports a defect that does not exist.
            total += occurrences(of: ".setProvider(id:", in: body)
        }
        XCTAssertTrue(files.contains("ProviderArming.swift"),
                      "VOID: could not read the file that holds the call — census measured nothing")
        XCTAssertEqual(total, 1, "production setProvider callers, across \(files.count) files: \(total)")
    }

    // MARK: - Helpers

    /// Whether the line carrying `needle` sits between `#if DEBUG` and its
    /// `#endif`. Line-scoped, because "the file mentions DEBUG somewhere" and
    /// "this call is DEBUG-only" are different claims.
    private func isInsideDebugBlock(needle: String, in body: String) -> Bool {
        var depth = 0
        var debugDepthFloor: Int? = nil
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") {
                depth += 1
                if t.contains("DEBUG"), debugDepthFloor == nil { debugDepthFloor = depth }
            } else if t.hasPrefix("#endif") {
                if let floor = debugDepthFloor, depth == floor { debugDepthFloor = nil }
                depth -= 1
            }
            if line.contains(needle) { return debugDepthFloor != nil }
        }
        return false
    }

    private func occurrences(of needle: String, in body: String) -> Int {
        body.components(separatedBy: needle).count - 1
    }

    /// Reads a source file from the repo. FAILS naming VOID when absent —
    /// never a skip: a census that silently measures nothing is a green that
    /// means nothing was checked.
    private func sourceFile(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // repo
        let url = root.appendingPathComponent("Sources/ZeusApp/\(name)")
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "VOID", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "VOID: no source at \(url.path) — this census measured nothing"])
        }
        return body
    }
}
