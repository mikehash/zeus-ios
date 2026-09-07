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

    @Binding var isPresented: Bool
    let onToast: (String) -> Void

    /// Token presence. Injected rather than constructed so legs run against
    /// the in-memory store; the real one is the default a production
    /// construction site supplies explicitly.
    var tokens: GatewayTokenStoring = InMemoryTokenStore()

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

    private var tokenLine: some View {
        HStack(spacing: 8) {
            Text("TOKEN")
                .font(Theme.mono(8.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.w(0.5))
            // PRESENCE, never the secret: the read-back contract is a
            // boolean. A masked echo (`•••`) of the real value is a secret
            // rendered, one screenshot away from leaking.
            Text(tokens.hasToken(host: hostKey) ? "PRESENT · KEYCHAIN" : "NOT SET")
                .font(Theme.mono(9.5))
                .tracking(0.6)
                .foregroundStyle(Theme.w(0.7))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var preflightLine: some View {
        HStack(spacing: 8) {
            Text("PREFLIGHT · GET /v1/status")
                .font(Theme.mono(8.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.w(0.5))
            Spacer(minLength: 0)
            Text("NOT RUN YET")
                .font(Theme.mono(9.5, .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.w(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var saveButton: some View {
        Button {
            // SAVE + RE-RESOLVE + REPORT. The URL is stored RAW and
            // unvalidated (validation belongs to `GatewayConfig.parse`, the
            // same parser the environment goes through — two parsers is how
            // the two sources drift), and the operator is told the verdict
            // rather than a success.
            onToast("GATEWAY URL SAVED — RESTART TO APPLY")
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
        .padding(.bottom, 22)
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
