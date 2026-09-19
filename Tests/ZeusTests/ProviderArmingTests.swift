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
    func stageAttachment(fileName: String, bytes: Data) throws -> String {
        "attachments/stub-\(fileName)"
    }

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
        func send(sessionId: String, text: String, images: [ImageAttachment], sink: TokenSink) throws {}
        func sessions() throws -> [SessionInfo] { [] }
        func messages(sessionId: String) throws -> [TurnMessage] { [] }
        func remember(fact: String) throws {}
        func search(query: String) -> [SearchHit] { [] }
    }

    private struct FixedArming: ProviderArming {
        let armed: Bool
        var thrower: Bool = false
        init(isArmed: Bool, thrower: Bool = false) { self.armed = isArmed; self.thrower = thrower }
        func isArmed() async throws -> Bool {
            if thrower { throw NSError(domain: "test", code: 7) }
            return armed
        }
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
    func testAnUnarmedCoreIsNotReadyEvenWithAProvider() async {
        let base = localResolution(commissioned(provider: "anthropic", model: "claude"))
        XCTAssertEqual(base.config, .local(.checking),
                       "PRECONDITION: the commission-only resolver answers CHECKING, never READY — the record may say no and may not say yes")

        let measured = await base.withCoreReadiness(FixedArming(isArmed: false))
        XCTAssertEqual(measured.config, .local(.noProvider),
                       "a core with no provider must not render READY, however many provider strings sit on disk")
    }

    /// The other arm. Both are asserted, and asserted to DIFFER, because a
    /// hardcoded readiness passes whichever single arm a test names.
    func testAnArmedCoreIsReady() async {
        let base = localResolution(commissioned(provider: "anthropic", model: "claude"))
        let armed = await base.withCoreReadiness(FixedArming(isArmed: true))
        let unarmed = await base.withCoreReadiness(FixedArming(isArmed: false))

        XCTAssertEqual(armed.config, .local(.ready))
        XCTAssertNotEqual(armed.config, unarmed.config,
                          "readiness that does not move with the core's answer is a constant wearing a function's name")
    }

    /// Remote arms are NOT the local core's subject and must pass through.
    func testRemoteResolutionsAreUntouchedByCoreReadiness() async {
        var c = commissioned(provider: "anthropic", model: "claude")
        c.deployment = .remote
        c.gatewayURL = "https://gw.example.com"
        let base = localResolution(c)
        guard case .resolved = base.config else {
            return XCTFail("VOID: fixture did not produce a resolved remote config — got \(base.config)")
        }
        let passed = await base.withCoreReadiness(FixedArming(isArmed: false))
        XCTAssertEqual(passed.config, base.config,
                       "a remote gateway's readiness is not this process's core to answer")
    }


    // MARK: - The type change (S3b)

    /// `.ready` IS UNREACHABLE FROM THE RECORD. The strongest form of the
    /// LIMIT this file's docstring named: the census leg used to be the only
    /// thing keeping `resolve` from promoting a string on disk to READY; now
    /// the signature is.
    func testTheRecordAloneCanNeverProduceReady() {
        for provider in ["anthropic", "openai", "ollama"] {
            let base = localResolution(commissioned(provider: provider, model: "m"))
            XCTAssertEqual(base.config, .local(.checking),
                           "resolve promoted a record to a claim about the core for \(provider)")
            XCTAssertNotEqual(base.config, .local(.ready))
        }
        // ...and the negative direction is still the record's to answer.
        XCTAssertEqual(localResolution(commissioned(provider: nil, model: nil)).config,
                       .local(.noProvider),
                       "\"the operator never picked a provider\" is a record fact and stays derivable")
    }

    /// `.checking` DISARMS, WITH ITS OWN SENTENCE. Three distinct strings, and
    /// asserted to differ: a send on an unmeasured core would land as
    /// `NoProvider` in the transcript, and saying NO PROVIDER while we have
    /// asked nothing is the wrong-subject claim this whole file exists for.
    func testCheckingDisarmsWithASentenceThatIsNotNoProvider() {
        let checking = GatewayConfig.local(.checking).disarmReason
        let noProvider = GatewayConfig.local(.noProvider).disarmReason
        XCTAssertNotNil(checking, "an unmeasured core must not arm the composer")
        XCTAssertNotEqual(checking, noProvider,
                          "CHECKING must not borrow NO PROVIDER's words — one is a claim about the core, the other is the absence of one")
        XCTAssertNil(GatewayConfig.local(.ready).disarmReason)
        XCTAssertEqual(checking, GatewayConfig.checkingMessage)
        XCTAssertNotEqual(GatewayConfig.local(.checking).summary,
                          GatewayConfig.local(.noProvider).summary,
                          "the summary must not collapse the two either")
    }

    /// A THROW IS NOT A NO. "The core refused to answer" and "the core has no
    /// provider" are different facts; folding the first into the second
    /// invents a measurement.
    func testACoreThatThrowsStaysCheckingRatherThanClaimingNoProvider() async {
        let base = localResolution(commissioned(provider: "anthropic", model: "claude"))
        let measured = await base.withCoreReadiness(FixedArming(isArmed: false, thrower: true))
        XCTAssertEqual(measured.config, .local(.checking),
                       "a failed read must not be rendered as a measured absence")
        XCTAssertNotEqual(measured.config, .local(.noProvider))
    }

    /// THE NINE SILENT SITES, PINNED.
    ///
    /// NINTH, added by Arc A and REVIEWED under this leg's own instruction:
    /// `LinkMonitor.probeOnce`'s `case .local:` asks "is the core local",
    /// and the answer is terminal for all three readiness sub-arms — an
    /// in-process core has no round trip to measure whether or not a provider
    /// has been picked. `HonestControlsTests` proves that over the whole
    /// `LocalReadiness` domain rather than over the one arm a fixture
    /// happened to use, which is what earns the non-destructuring form here.
    ///
    /// THE ORIGINAL EIGHT. `LocalReadiness` is not `CaseIterable`
    /// and `case .local:` binds the payload without inspecting it, so adding
    /// `.checking` reded exactly TWO switches and the compiler named none of
    /// the rest. These eight ask "is the core local", not "is it ready", and
    /// that is deliberate — asserted here so the NEXT case is reviewed rather
    /// than passed through.
    func testTheNonDestructuringLocalSitesAreDeliberate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        var nonDestructuring = 0, destructuring = 0, negative = 0
        for f in files {
            for line in try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
                            .split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                guard l.contains("case .local") || l.contains("case .local =") else { continue }
                if l.contains("case .local(") { destructuring += 1 } else { nonDestructuring += 1 }
                if l.contains("case .zzzlocal") { negative += 1 }
            }
        }
        XCTAssertEqual(negative, 0, "VOID: the counter matched a pattern that does not exist")
        XCTAssertGreaterThan(destructuring, 0, "VOID: no destructuring sites found — the scan did not reach the sources")
        XCTAssertEqual(nonDestructuring, 9,
                       "the count of `.local` matches that do NOT inspect readiness moved. The compiler will not name them: `LocalReadiness` is not CaseIterable and `case .local:` binds without inspecting. Read each one and decide whether it means \"is the core local\" (leave it) or \"is it ready\" (destructure it), then move this number.")
    }

    /// THE SPLIT, AT THE PRODUCTION SYMBOL. The leg below proves the ORDER is
    /// load-bearing; this one proves the order is still there in
    /// `armedResolution` — which the behavioural leg cannot see, because
    /// `armedResolution` reaches `EmbeddedCapabilities.shared()` and takes no
    /// injected core, so a test can only compose its own copy of the act.
    ///
    /// A copy asserts a property of the copy. That is the S3a lesson repeated
    /// one file over, and this is the guard it earned: the arm, the resolve
    /// and the compose must sit in ONE act in the shipped function. Wrap the
    /// arm in a `Task {` and the compose reads a core armed a beat later —
    /// exactly the defect the comment at the call site names.
    func testArmAndComposeAreOneActInTheShippedHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeusApp")
        let lines = try String(contentsOf: root.appendingPathComponent("RootView.swift"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let start = lines.firstIndex(where: { $0.contains("static func armedResolution") }),
              let end = lines[start...].firstIndex(where: { $0.contains("return await RootView.resolve(store: store)") })
        else {
            return XCTFail("VOID: armedResolution or its composing return is no longer findable")
        }
        let bodyLines = Array(lines[start...end])

        // POS control: the instrument reaches the body it claims to read.
        XCTAssertTrue(bodyLines.contains { $0.contains("CoreArming.arm(") },
                      "VOID: the arm call is not inside the slice being scanned")
        // NEG control: the needle is not matching everything.
        XCTAssertFalse(bodyLines.contains { $0.contains("ZzzNoSuchCall(") })

        let detached = bodyLines.filter {
            !$0.hasPrefix("//") && !$0.hasPrefix("///")
                && ($0.contains("Task {") || $0.contains("Task.detached"))
        }
        XCTAssertTrue(detached.isEmpty,
                      "arm → resolve → compose must stay ONE act; a detached task here lets the "
                      + "compose read a core armed a beat later. Found: \(detached)")
    }

    /// STALE-CACHE. The arm and the read are ONE act: a resolution composed
    /// before `arm` ran renders the pre-arm answer. Split
    /// arm → resolve → compose into two tasks and this reds.
    func testAResolutionComposedBeforeArmingIsNotReady() async {
        let core = ArmingCore()
        let commission = commissioned(provider: "anthropic", model: "claude-x")
        let base = localResolution(commission)

        // Compose FIRST (the split-task order): the core has not been armed.
        let early = await base.withCoreReadiness(EmbeddedCoreArming(core: EmbeddedCapabilities(core: core)))
        XCTAssertEqual(early.config, .local(.noProvider),
                       "a read taken before the arm must not render READY")

        // Now the single-act order: arm, THEN compose.
        CoreArming.arm(commission: commission,
                       core: EmbeddedCapabilities(core: core),
                       providerKey: "sk-real",
                       baseURL: nil)
        let late = await base.withCoreReadiness(EmbeddedCoreArming(core: EmbeddedCapabilities(core: core)))
        XCTAssertEqual(late.config, .local(.ready))
        XCTAssertNotEqual(early.config, late.config,
                          "VACUITY: the two orders must differ, or this leg cannot detect the split")
    }

    // MARK: - Arming

    func testArmPassesTheCommissionProviderAndModelToTheCore() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "anthropic", model: "claude-x"),
                                    core: EmbeddedCapabilities(core: core),
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
                                    core: EmbeddedCapabilities(core: core),
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
                           core: EmbeddedCapabilities(core: core),
                           providerKey: nil,
                           // Ollama is a `.url` provider and the arm now
                           // refuses one with no endpoint, so this leg supplies
                           // the half it is not about. It went red on the (i)
                           // cut, which is the refusal reaching the REAL
                           // catalog — the core's own verdict, not a stub's.
                           baseURL: "http://127.0.0.1:11434")
        XCTAssertEqual(core.setCalls.first?.key, CoreArming.ollamaKeyPlaceholder)
        XCTAssertFalse(CoreArming.ollamaKeyPlaceholder.isEmpty,
                       "an empty key is refused by the core with an error naming the header, not the key")
    }

    // MARK: - keylessness is derived, not listed

    /// THE DISCRIMINATING ROW. A `.none`-shape provider whose id is NOT
    /// "ollama" must send the placeholder — and the retired
    /// `keylessProviders: Set<String> = ["ollama"]` answered this WRONG,
    /// because keylessness was a membership test on an id rather than the
    /// core's verdict on the provider. It would have demanded a key for a
    /// provider that has none to give and refused to arm at all.
    ///
    /// A stub catalog owns the shapes so this is a leg about the DERIVATION,
    /// not about which providers the linked core ships today.
    func testANonOllamaKeylessProviderStillSendsThePlaceholder() {
        let saved = ProviderCatalog.current
        defer { ProviderCatalog.current = saved }
        ProviderCatalog.current = StubCatalog(
            rows: [ProviderRow(id: "ambient", label: "Ambient OAuth", shape: .none)])

        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "ambient", model: "m1"),
                                    core: EmbeddedCapabilities(core: core),
                                    providerKey: nil,
                                    baseURL: nil)

        XCTAssertNil(reason, "a keyless provider needs no key: \(reason ?? "")")
        XCTAssertEqual(core.setCalls.first?.key, CoreArming.ollamaKeyPlaceholder)
        // VACUITY: the id must really be outside the retired literal, or this
        // leg passes under the very predicate it was written to retire.
        XCTAssertNotEqual("ambient", "ollama",
                          "the fixture id must not be the one the old literal named")
    }

    /// The opposite arm, in the same suite: a `.key` provider is NOT keyless,
    /// so a missing key refuses rather than silently arming the core with a
    /// placeholder an authenticating provider would reject as a 401.
    func testAKeyedProviderIsNotKeylessAndRefusesWithoutAKey() {
        let saved = ProviderCatalog.current
        defer { ProviderCatalog.current = saved }
        ProviderCatalog.current = StubCatalog(
            rows: [ProviderRow(id: "acme", label: "Acme AI", shape: .key)])

        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "acme", model: "m1"),
                                    core: EmbeddedCapabilities(core: core),
                                    providerKey: nil,
                                    baseURL: nil)

        XCTAssertEqual(reason, "NO KEY FOR Acme AI — ENTER ONE IN ROUTES")
        XCTAssertTrue(core.setCalls.isEmpty, "refused must mean NOT ARMED")
    }

    /// `.unsupported` is deliberately not keyless. Arming it with a
    /// placeholder would send the core a credential for a provider whose
    /// requirements this build does not know — the shape's whole meaning is
    /// that the app cannot collect for it.
    func testAnUnsupportedProviderIsNotTreatedAsKeyless() {
        XCTAssertFalse(CoreArming.usesKeyPlaceholder(.unsupported(reason: "needs a service account")))
        // POS control in the same invocation: the predicate does answer true
        // for something, so the false above is a verdict and not a stuck no.
        XCTAssertTrue(CoreArming.usesKeyPlaceholder(.none))
        XCTAssertTrue(CoreArming.usesKeyPlaceholder(.url))
        XCTAssertFalse(CoreArming.usesKeyPlaceholder(.key))
    }

    /// The literal is gone from CODE lines. Comments are excluded because the
    /// doc comment on `usesKeyPlaceholder` NAMES the retired symbol to explain
    /// what it replaced — a whole-file needle would hit my own explanation of
    /// the deletion.
    func testTheKeylessProviderListIsRetiredFromCodeLines() throws {
        let body = try sourceFile("ProviderArming.swift")
        let code = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                return (t.hasPrefix("///") || t.hasPrefix("//")) ? "" : String(line)
            }
            .joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "keylessProviders", in: code), 0,
                       "the hardcoded provider list must not survive on code lines")
        XCTAssertEqual(occurrences(of: "\"ollama\"", in: code), 0,
                       "no provider id literal decides keylessness any more")
        // POS control: the filter did not simply blank the file.
        XCTAssertGreaterThan(occurrences(of: "usesKeyPlaceholder", in: code), 0,
                             "VOID: the code-line filter removed everything, so both zeros above are about my needle")
    }

    /// UNARMED ≠ UNREACHABLE — two distinct strings, an equality leg on each.
    /// A single "something went wrong" for both is how an operator restarts
    /// the app to fix a daemon that is not running.
    func testUnarmedAndUnreachableAreDifferentStrings() {
        let noProvider = CoreArming.arm(commission: commissioned(provider: nil, model: nil),
                                        core: EmbeddedCapabilities(core: ArmingCore()),
                                        providerKey: nil,
                                        baseURL: nil)
        XCTAssertEqual(noProvider, GatewayConfig.noProviderMessage)

        let refusing = ArmingCore()
        refusing.setThrows = true
        let refused = CoreArming.arm(commission: commissioned(provider: "ollama", model: "llama3.2"),
                                     core: EmbeddedCapabilities(core: refusing),
                                     providerKey: nil,
                                     baseURL: "http://127.0.0.1:11434")
        XCTAssertNotNil(refused)
        XCTAssertNotEqual(refused, GatewayConfig.noProviderMessage,
                          "a provider that refused the call is not a provider nobody chose")
        XCTAssertTrue(refused?.contains("REFUSED") == true, "got \(refused ?? "nil")")
    }

    /// GATE TWO, BEHAVIOURAL: a `.url` provider with no endpoint is REFUSED
    /// rather than armed against the bridge's localhost fallback.
    ///
    /// On the simulator localhost is the Mac and the fallback happens to work;
    /// on a phone localhost is the phone, so the route can never reach the
    /// operator's rig and fails as a connection error naming the wrong cause.
    func testAURLProviderWithNoEndpointIsRefusedAndNeverArmed() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "ollama", model: "llama3.2"),
                                    core: EmbeddedCapabilities(core: core),
                                    providerKey: nil,
                                    baseURL: nil)
        XCTAssertEqual(reason, "NO ENDPOINT FOR Ollama — ENTER ONE IN ROUTES")
        XCTAssertTrue(core.setCalls.isEmpty,
                      "refused means NOT ARMED: a reason string beside a live setProvider call "
                      + "is the worst of both — the screen says unarmed and the core is armed wrong")

        // POS + DISCRIMINATOR in the same invocation: the same call with an
        // endpoint arms, and it arms WITH THAT ENDPOINT. Without this the leg
        // above is a statement about `arm` refusing everything.
        let armed = CoreArming.arm(commission: commissioned(provider: "ollama", model: "llama3.2"),
                                   core: EmbeddedCapabilities(core: core),
                                   providerKey: nil,
                                   baseURL: "http://10.0.0.2:11434")
        XCTAssertNil(armed, "POS: with an endpoint it arms")
        XCTAssertEqual(core.setCalls.first?.baseUrl, "http://10.0.0.2:11434",
                       "the operator's endpoint reaches the core verbatim")
    }

    func testAMissingModelIsNamedNotGuessed() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "anthropic", model: nil),
                                    core: EmbeddedCapabilities(core: core),
                                    providerKey: "sk-real",
                                    baseURL: nil)
        XCTAssertEqual(reason, "NO MODEL — Anthropic LISTED NONE")
        XCTAssertTrue(core.setCalls.isEmpty,
                      "a model the app invented is a model no provider serves — the call must not be made")
    }

    func testAKeyedProviderWithoutAKeyIsNamed() {
        let core = ArmingCore()
        let reason = CoreArming.arm(commission: commissioned(provider: "anthropic", model: "claude"),
                                    core: EmbeddedCapabilities(core: core),
                                    providerKey: nil,
                                    baseURL: nil)
        XCTAssertEqual(reason, "NO KEY FOR Anthropic — ENTER ONE IN ROUTES")
        XCTAssertTrue(core.setCalls.isEmpty)
    }

    // MARK: - The model comes from the provider

    func testFirstModelReturnsTheProvidersFirstEntry() {
        let core = ArmingCore()
        core.models = ["llama3.2:latest", "qwen3.8:27b-mlx"]
        XCTAssertEqual(CoreArming.firstModel(for: "ollama", core: EmbeddedCapabilities(core: core), key: nil, baseURL: nil),
                       "llama3.2:latest")
    }

    /// v1's `list_models` is Ollama-only. A provider that cannot answer must
    /// yield nil, NOT a fabricated model name.
    func testAProviderThatCannotListYieldsNil() {
        let core = ArmingCore()
        core.listThrows = true
        XCTAssertNil(CoreArming.firstModel(for: "anthropic", core: EmbeddedCapabilities(core: core), key: "sk", baseURL: nil))
    }

    func testRecordRoutesChoiceStoresTheProvidersModel() {
        var c = Commission()
        c.recordRoutesChoice(providerID: "ollama", model: "llama3.2:latest", baseURL: nil)
        XCTAssertEqual(c.provider, "ollama")
        XCTAssertEqual(c.model, "llama3.2:latest")

        var none = Commission()
        none.recordRoutesChoice(providerID: "anthropic", model: nil, baseURL: nil)
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
        // THREE as of Arc B. The third is the ROUTES COMMIT: setting a
        // provider from NODES must re-arm for exactly the reason the gateway
        // save must — `configSource` is a `@StateObject` and the adopting
        // `.task` has no `id:`, so a record write alone leaves the pill and
        // the AGENT tile reading NO PROVIDER until relaunch. The number moved
        // for a stated reason; the leg still reds on an UNEXPLAINED move.
        XCTAssertEqual(lines.filter { $0.contains("armedResolution(store: store, keys: keys)") }.count, 3,
                       "VOID or drift: expected three entry points (init + gateway onSaved + routes commit) into the armed helper")

        // The bare resolver may appear ONLY inside the helper — one call, and
        // it is the one the helper composes onto.
        // THREE SITES, EACH NAMED — not a raised number.
        //
        // A bare count bump would permanently weaken this instrument: it would
        // admit a fourth site anywhere. The two new ones are the SEED (`init`
        // is not an async context, so the measured arm cannot be constructed
        // there) and the INVALIDATION (a save drops the badge to `.checking`
        // before the re-read). Both are the pure resolver used AS the
        // `.checking` producer, which is the opposite of dropping the core's
        // answer — and both are followed by a composing read.
        // FOUR as of Arc B — the fourth is the routes commit's invalidation,
        // named in the leg below beside the gateway save's. Still every
        // occurrence enumerated by FORM, never a raised number.
        let bare = lines.filter { $0.contains("RootView.resolve(store: store)") }
        XCTAssertEqual(bare.count, 4,
                       "a bare `RootView.resolve` outside the helper drops the core's readiness answer; found \(bare.count)")
        XCTAssertEqual(lines.filter { $0.contains("let resolution = RootView.resolve(store: store)") }.count, 1,
                       "the init seed must be exactly one site")
        // TWO invalidation sites, and they are the SAME act at two doors:
        // the gateway save and the routes commit each drop the badge to
        // `.checking` before their re-read. Identical in form because they
        // are identical in kind — this is the pure resolver used AS the
        // `.checking` producer, not as a substitute for the armed one.
        XCTAssertEqual(lines.filter { $0.contains("configSource.adopt(RootView.resolve(store: store))") }.count, 2,
                       "the save-invalidation sites are the gateway save and the routes commit")
        XCTAssertEqual(lines.filter { $0.contains("return await RootView.resolve(store: store)") }.count, 1,
                       "the helper's own composing resolve must be exactly one site")

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
