import SwiftUI

/// The remote-gateway editor — G0's operator surface.
///
/// OPENED FROM two affordances (the HOME LINK pill, the NODES gateway row),
/// which is why it lives as its own type and not inline in either view: it
/// is the ONE sheet both tabs reach, and inlining it would fork the fork.
///
/// CONSUMES, NEVER REDECLARES: the config arm and its `Source` provenance
/// arrive from `RootView`'s one resolution (`resolve(from:store:)`,
/// `GatewayConfig.swift:182`). This view adds no new source of truth about
/// where the app looks — it shows the decision and edits it.
///
/// WHAT IT WRITES vs READS (the producer statement):
///   WRITES  — `Commission.gatewayURL` (raw string) via `store.save`, and
///             the token via the Keychain as a generic password keyed by the
///             URL's host, NEVER `UserDefaults`. On save it re-resolves and
///             reports the verdict, so the operator cannot leave the sheet
///             believing a broken URL saved.
///   READS   — the arm + provenance (constructor), the raw URL from the
///             commission blob on relaunch, and the token's PRESENCE from
///             the Keychain (a boolean — the secret is never displayed).
struct GatewayEditorSheet: View {

    /// The arm the console was built from — captured at open time, so the
    /// sheet labels what the app is DOING, not what a re-resolve mid-edit
    /// would say now.
    let config: GatewayConfig

    /// The provenance of `config` — `environment`, `commission`, `unset`.
    /// Shown because an operator running off `ZEUS_GATEWAY_URL` from a
    /// scheme argument sees "correct but unasked-for" behaviour, and the
    /// provenance is the only line that explains it.
    let resolution: GatewayConfig.Resolution

    /// Token store — INJECTED, no default. `RootView` owns the one
    /// construction (Keychain in production, in-memory under the
    /// `-zeusInMemoryTokens` launch seam), so what the sheet writes to is
    /// the same store every launch decided on. A default here would let a
    /// call site silently ship an editor writing to a throwaway store.
    let tokens: GatewayTokenStoring

    /// The commission store the URL half writes through — INJECTED, no
    /// default, for the same reason `tokens` has none: a default here would
    /// let a call site ship an editor persisting to a throwaway store, and
    /// the write would be invisible at every leg that asserts what the
    /// WRITER returns rather than which store the caller handed it. That is
    /// the exact defect `RootView`'s own docstring records (it swapped the
    /// store for a fresh `UserDefaultsCommissionStore()` and 294 tests
    /// stayed green); this is the surface that stops it recurring.
    let store: CommissionStoring

    @Binding var isPresented: Bool

    /// The SAME precedence the wire uses. Injected rather than constructed so
    /// the preflight and the transport cannot disagree about what was sent —
    /// a verdict computed over a different credential than the session will
    /// carry is a verdict about a request nobody makes.
    let credentials: CredentialProviding

    /// Re-resolve. Called AFTER the write, so the source adopts a config
    /// derived from what is now on disk rather than from the field. NO
    /// DEFAULT: an empty closure default is how a SAVE that persists and does
    /// not apply looks green — the four surfaces stay on the launch host and
    /// nothing says so.
    let onSaved: () -> Void

    let onToast: (String) -> Void

    /// The URL field is SEEDED IN INIT, not on appear and not lazily: seed
    /// logic in `body` re-runs per render (and would fight the operator's
    /// typing), `onAppear` runs after first paint (a frame with an empty
    /// field), and an init assignment runs exactly once, before the field
    /// exists to disagree with it.
    /// `seedToken` exists for ONE reason and it is stated so nobody deletes
    /// it as unused: `@State` cannot be written from outside a renderer (the
    /// write lands in a nil `_location` and is dropped), so the only way a
    /// leg can exercise the TYPED-token arm of the verdict is to seed the
    /// field at construction — the same `State(initialValue:)` seam the URL
    /// already uses at the line below. Production passes nothing; the
    /// default keeps the one production call site (`RootView.swift:172`)
    /// unchanged and keeps the field empty on every real launch.
    /// `credentials` has NO DEFAULT, deliberately. A default of
    /// `KeychainCredentialProvider()` is not a test double — it is an
    /// unlogged dependency on the HOST's state: on a simulator with an empty
    /// Keychain it answers `nil` to everything, so every "no credential was
    /// attached" leg passes on the empty store rather than on the wiring.
    /// The one live construction is `RootView.swift` (`Sources` census == 1).
    init(config: GatewayConfig,
         resolution: GatewayConfig.Resolution,
         tokens: GatewayTokenStoring,
         store: CommissionStoring,
         isPresented: Binding<Bool>,
         transport: PreflightTransporting = URLSessionPreflight(),
         credentials: CredentialProviding,
         seedToken: String = "",
         onSaved: @escaping () -> Void,
         onToast: @escaping (String) -> Void) {
        self.config = config
        self.resolution = resolution
        self.tokens = tokens
        self.store = store
        self._isPresented = isPresented
        self.transport = transport
        self.credentials = credentials
        self.onSaved = onSaved
        self.onToast = onToast
        _url = State(initialValue: Self.seedURL(for: config))
        _newToken = State(initialValue: seedToken)
    }

    /// What a URL SAVE actually did. Three outcomes, not a `Bool`, because
    /// "no commission on disk" is not "nothing changed": it is the one case
    /// where the operator typed an endpoint and the app has nowhere to put
    /// it, and a surface that reports it as a plain no-op would be claiming
    /// a persistence it did not perform.
    enum URLWrite: Equatable { case wrote, cleared, noCommission }

    /// The URL half of SAVE. EXTRACTED FROM THE BUTTON CLOSURE for the
    /// reason recorded at `Commission.recordDeployment`: a mutation living
    /// only inside a SwiftUI closure is unreachable in-process, so deleting
    /// it costs nothing measurable and every leg stays green. As a method it
    /// has a call site a census can count and a return value a leg can read.
    ///
    /// Writes through `store` — the instance this sheet was HANDED, never a
    /// fresh one — and through `Commission.recordGatewayURL`, the sole
    /// writer of that field.
    @discardableResult
    func commitURL() -> URLWrite {
        guard var commission = store.load() else { return .noCommission }
        commission.recordGatewayURL(urlOrSeed)
        store.save(commission)
        return commission.gatewayURL == nil ? .cleared : .wrote
    }

    /// The SAVE receipt. Static and total over the two halves so the string
    /// is testable without a renderer.
    ///
    /// `LIVE NOW` replaced `APPLIES ON NEXT LAUNCH` at c2, and the swap is
    /// the whole point of that commit: the four byte-sending surfaces now
    /// observe `GatewayConfigSource` and re-derive on `onSaved()`, so the
    /// old caption became the lie its own leg promised to catch. The leg
    /// inverted with it — `APPLIES ON NEXT LAUNCH` must now read 0 in
    /// `Sources`, and `LIVE NOW` may only be said by a build where
    /// `RootView` holds no `private let config` for those surfaces.
    static func saveToast(savedToken: Bool, url: URLWrite) -> String {
        switch (savedToken, url) {
        case (_, .noCommission):
            return savedToken ? "TOKEN SAVED · NO COMMISSION — URL NOT STORED"
                              : "NO COMMISSION — URL NOT STORED"
        case (true, .wrote):    return "TOKEN SAVED · URL SAVED — LIVE NOW"
        case (true, .cleared):  return "TOKEN SAVED · URL CLEARED — LIVE NOW"
        case (false, .wrote):   return "URL SAVED — LIVE NOW"
        case (false, .cleared): return "URL CLEARED — LIVE NOW"
        }
    }

    /// The four preflight outcomes. TRANSPORT FAILURE IS ITS OWN STATE: a
    /// dead host and a wrong token are different subjects and the operator
    /// fixes them differently — folding a refused connection into TOKEN
    /// REJECTED sends him hunting for a credential while the gateway is
    /// down.
    enum PreflightState: Equatable {
        case tokenOK
        case tokenRejected
        case noTokenBlocked
        case gatewayUnreachable
    }

    /// The transport preflight runs over. A protocol so the legs can stub
    /// responses AND so the button path is exercised against the seam the
    /// production `URLSession` sits behind — the four mapping legs assert
    /// `preflightState(...)` directly; the button legs assert the CALL
    /// reaches it, which a direct-mapping test cannot see.
    let transport: PreflightTransporting

    /// The run's verdict. `@State` because it is sheet-local: two sheets
    /// open in one process (impossible today, one flag) would not share a
    /// preflight result any more than they share the `@State` URL field.
    @State private var preflight: PreflightState?

    /// Shared row rendering for the four verdicts — the states differ in
    /// label and tint, never in shape; a fifth shape is a defect here.
    private func preflightLabel(_ state: PreflightState) -> (String, Color) {
        switch state {
        case .tokenOK:            return ("TOKEN OK — GATEWAY REACHABLE", Theme.ok)
        case .tokenRejected:      return ("TOKEN REJECTED — REPLACE IT ABOVE", Theme.danger)
        case .noTokenBlocked:     return ("NO TOKEN — ADD ONE ABOVE TO UNBLOCK", Theme.warn)
        case .gatewayUnreachable: return ("GATEWAY UNREACHABLE — CHECK THE URL", Theme.warn)
        }
    }

    /// Static because a SwiftUI body is not observable in-process — the
    /// four preflight legs exercise this mapping directly, the same
    /// aperture rule the rest of this suite states.
    static func preflightState(httpStatus: Int?, hadToken: Bool,
                               transportFailed: Bool) -> PreflightState {
        if transportFailed { return .gatewayUnreachable }
        guard let status = httpStatus else { return .gatewayUnreachable }
        switch status {
        case 200..<300: return .tokenOK
        case 401:       return hadToken ? .tokenRejected : .noTokenBlocked
        default:        return hadToken ? .tokenRejected : .noTokenBlocked
        }
    }

    var body: some View {
        SheetLayer(isPresented: $isPresented,
                   title: "REMOTE GATEWAY",
                   subtitle: "source · \(resolution.source.rawValue)") {
            ScrollView {
                VStack(spacing: 0) {
                    provenanceLine
                    urlField
                    tokenLine
                    preflightLine
                    saveButton
                }
            }
        }
    }

    // MARK: - Rows

    @State private var url: String = ""

    private var provenanceLine: some View {
        Text(config.summary)
            .font(Theme.mono(9))
            .tracking(0.9)
            .foregroundStyle(Theme.w(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GATEWAY URL")
                .font(Theme.mono(8.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.w(0.5))
            TextField("https://zeus.local:8080", text: $url)
                .font(Theme.mono(11))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.barCorner,
                                            style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// The entry field for a NEW token. `@State` (sheet-local, never
    /// re-read from the store — the store's read contract is presence-only,
    /// and an echo of the stored secret would break it), and EMPTY means
    /// "leave the stored one alone": SAVE writes only a non-empty field, so
    /// an operator who opens the sheet to fix a URL cannot accidentally
    /// blank a stored credential.
    @State private var newToken: String = ""

    private var tokenLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TOKEN")
                .font(Theme.mono(8.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.w(0.5))
            SecureField("API TOKEN", text: $newToken)
                .font(Theme.mono(11))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.barCorner,
                                            style: .continuous))
            HStack(spacing: 8) {
                // PRESENCE, never the secret: the read-back contract is a
            // boolean. A masked echo (`•••`) of the real value is a secret
            // rendered, one screenshot away from leaking.
                Text(tokens.hasToken(host: Self.hostKey(for: config)) ? "PRESENT · KEYCHAIN" : "NOT SET")
                    .font(Theme.mono(9.5))
                    .tracking(0.6)
                    .foregroundStyle(Theme.w(0.7))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// The URL preflight RUNS against. `seedURL(for:)`'s live arm — what
    /// the field holds, falling back to the config's own operand when the
    /// operator has not typed anything yet, so PREFLIGHT checks the URL he
    /// is about to save, not the one he is replacing.
    private var urlOrSeed: String {
        url.isEmpty ? Self.seedURL(for: config) : url
    }

    private var preflightLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("PREFLIGHT · GET /v1/status")
                    .font(Theme.mono(8.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.w(0.5))
                Spacer(minLength: 0)
                if let preflight {
                    let (label, tint) = preflightLabel(preflight)
                    Text(label)
                        .font(Theme.mono(9.5, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(tint)
                } else {
                    Text("NOT RUN YET")
                        .font(Theme.mono(9.5, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.w(0.4))
                }
            }
            Button {
                runPreflight()
            } label: {
                Text("RUN PREFLIGHT")
                    .font(Theme.display(9.5, .bold))
                    .tracking(1.9)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.controlSize)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// The button path: field → transport → mapping. Extracted as a method
    /// so the legs can call THE PATH the button calls, not a parallel copy
    /// of its body — a private-in-view closure is unobservable in-process,
    /// a method on the struct is not.
    func runPreflight() {
        Task { @MainActor in
            preflight = await computePreflight()
        }
    }

    /// The verdict, computed and RETURNED rather than only assigned.
    ///
    /// Why a returning method exists at all: `preflight` is `@State`, and a
    /// `@State` write outside a renderer lands in a nil `_location` and is
    /// DROPPED — so a leg that called `runPreflight()` and then dug the
    /// property could never see the verdict, and would report the initial
    /// nil as the outcome. The state a test can observe must be the value
    /// the production path computes, not a copy of its arithmetic.
    ///
    /// ONE binding, read twice: the value handed to the transport IS the
    /// value the verdict is computed from. `hadToken` means "the request
    /// carried a bearer" — never "a credential exists somewhere".
    ///
    /// The defect this shape retires: `hadToken` was taken from
    /// `tokens.hasToken(host:)`, so after any relaunch (the field starts
    /// empty and is never seeded — the secret is not read back out of the
    /// store, by contract) a 401 rendered TOKEN REJECTED for a credential
    /// that was never in the request, telling the operator to destroy a
    /// working token. The store answers a DIFFERENT question than the one
    /// the verdict asks, and the two coincide only while the field is full.
    func computePreflight() async -> PreflightState {
        // TYPED FIELD WINS, then the provider. A token the operator just
        // typed is the thing he is asking about; with the field empty the
        // preflight must exercise what the SESSION would send, which is the
        // provider's answer and nothing else. `hadToken` is still read off
        // this one binding, so the verdict describes the request that was
        // actually made — including the reachable case where the presence
        // store says PRESENT and the provider hands back nothing (an item the
        // Keychain will not return data for), which is NO TOKEN, not REJECTED.
        let bearer: String? = newToken.isEmpty ? providerCredential : newToken
        let reply = await transport.status(url: urlOrSeed, bearer: bearer)
        return Self.preflightState(httpStatus: reply.httpStatus,
                                   hadToken: bearer != nil,
                                   transportFailed: reply.transportFailed)
    }

    /// The provider's answer for the endpoint under edit. Nil for every
    /// non-resolved arm — there is no endpoint to hold a credential for.
    private var providerCredential: String? {
        guard case .resolved(let endpoint) = config else { return nil }
        return credentials.credential(for: endpoint)
    }

    private var saveButton: some View {
        VStack(spacing: 8) {
            Button {
            // The TOKEN half is REAL: Keychain (or the in-memory twin under
            // the launch seam) at the config's host key. The URL half is
            // DISABLED until ③ lands `Commission.gatewayURL` — the toast
            // reports exactly what was written, never a persistence it did
            // not perform.
            let host = Self.hostKey(for: config)
            let savedToken: Bool
            if !newToken.isEmpty, !host.isEmpty {
                tokens.save(token: newToken, host: host)
                savedToken = true
            } else {
                savedToken = false
            }
            let urlOutcome = commitURL()
            // Order is load-bearing: the write, THEN the re-resolve, THEN the
            // receipt. Re-resolving first would adopt the config still on
            // disk and report a URL that never applied.
            onSaved()
            onToast(Self.saveToast(savedToken: savedToken, url: urlOutcome))
            isPresented = false
        } label: {
            Text("SAVE")
                .font(Theme.display(9.5, .bold))
                .tracking(1.9)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.controlSize)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            Text("SAVE APPLIES IMMEDIATELY")
                .font(Theme.mono(8))
                .tracking(0.7)
                .foregroundStyle(Theme.w(0.4))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 22)
        }
    }

    /// Seeded from the RESOLVED endpoint when there is one; a malformed
    /// operand seeds the field with the broken raw string so the operator
    /// edits WHAT failed rather than retyping from scratch. Static for the
    /// same reason every derivation in this tree is static: a SwiftUI body
    /// is not observable in-process, so the seeding leg exercises this
    /// mapping directly.
    static func seedURL(for config: GatewayConfig) -> String {
        switch config {
        case .resolved(let endpoint): return endpoint.url.absoluteString
        case .malformed(let raw, _):  return raw
        case .absent, .local:         return ""
        }
    }

    /// The Keychain account for this config's token: the endpoint's host
    /// when there is one, empty (never read as a key) when there is not.
    /// Same aperture note as `seedURL`.
    static func hostKey(for config: GatewayConfig) -> String {
        switch config {
        case .resolved(let endpoint): return endpoint.url.host ?? ""
        case .malformed(let raw, _):  return URL(string: raw)?.host ?? ""
        case .absent, .local:         return ""
        }
    }
}

// MARK: - Preflight transport

/// One method on purpose: everything else about the request (timeout, 
/// headers beyond the bearer) is `URLSession` configuration, and each knob
/// hoisted here is one more a leg must stub. The mapping under test is
/// `preflightState(...)`, not HTTP itself.
protocol PreflightTransporting: AnyObject {
    func status(url: String, bearer: String?) async -> (httpStatus: Int?, transportFailed: Bool)
}

/// The production transport. `GET /v1/status` with the bearer when one is
/// supplied — a missing credential must produce the gateway's 401, not a
/// client-side error folded into UNREACHABLE, which is why the request is
/// sent WITHOUT a bearer rather than short-circuited locally when
/// `bearer` is nil.
final class URLSessionPreflight: PreflightTransporting, @unchecked Sendable {
    func status(url: String, bearer: String?) async -> (httpStatus: Int?, transportFailed: Bool) {
        guard let target = URL(string: url) else {
            return (nil, true)   // an unparseable URL is unreachable, full stop
        }
        var request = URLRequest(url: target.appending(path: "v1/status"))
        request.timeoutInterval = 10
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode
            return (code, false)
        } catch {
            return (nil, true)
        }
    }
}
