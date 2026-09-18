import SwiftUI

/// THE ROUTE PICKER, EXTRACTED SO IT CAN BE REACHED FROM TWO PLACES.
///
/// It was `CommissioningView.routesStep` — a ~215-line `@ViewBuilder` over
/// eight pieces of private `@State` plus two private poll methods. Making a
/// provider choosable after onboarding needed that surface from `NODES`, and
/// there were only two shapes available: paste it, or move it.
///
/// PASTING WOULD HAVE SHIPPED GREEN AND UNGUARDED. Every census that holds
/// this picker honest is FILE-SCOPED on `Commissioning.swift` — the ban on
/// provider literals, "the model field is not gated on the catalog" (the
/// Ollama-only defect in its newest costume), "one key write site", "the
/// debounce cancels the in-flight poll", "no prefilled localhost". A second
/// copy in `NodesView.swift` inherits NONE of them: it could hardcode a
/// vendor id, gate the free-text field on `.listed`, and open one HTTP
/// request per keystroke, with all five legs still green. (Not quoting one
/// here: the literal ban reads RAW source by design, because a comment
/// quoting an id is indistinguishable from a constant naming one, and the
/// guard says so rather than pretending to tell them apart.) So the code moved
/// HERE and the censuses moved WITH it — they now read this file, and
/// `RoutePickerCensusTests` asserts they are no longer reading only the one
/// they came from.
///
/// WHAT IT DOES NOT OWN: the commit. `onCommit` hands the three chosen values
/// UP, because writing a commission is not the same act as re-arming the core
/// — see `RootView`, which owns both and sequences them.
struct RoutePicker: View {

    /// Where a typed provider key lands. NO DEFAULT, for the same reason
    /// `CommissioningView` has none: a default lets a future call site omit
    /// the store and write the operator's secret into a stand-in that forgets
    /// it, which reads as "the key did not save" one screen later.
    let keys: ProviderKeyStoring

    /// The CTA's label. Onboarding continues a flow ("VALIDATE + CONTINUE");
    /// the NODES sheet ends one ("SET ROUTE"). The WORD differs because the
    /// act differs, and a shared component that lies about which act it is
    /// performing is the narration defect this app keeps retiring.
    let ctaTitle: String

    /// The three values the operator chose, handed UP. This component never
    /// writes a `Commission` and never re-arms anything: the sequencing of
    /// record-write → re-resolve → re-arm belongs to whoever owns the store,
    /// and here that is `RootView`.
    let onCommit: (String, String, String) -> Void


    /// The provider row the operator has TAPPED, held in the view.
    ///
    /// Same shape as `forkPick` one field over: a preselection is what the
    /// screen is showing, not what the flow produced. `commission.provider`
    /// stays nil until CONTINUE writes it, so "was shown a list" and "chose"
    /// remain distinguishable in the stored record.
    @State private var providerPick: String? = nil

    /// The model, TYPED or PICKED. Required for every shape.
    ///
    /// There is no default literal and no guess. The field is always present
    /// and never replaced by the picker: `list_models` now delegates to
    /// `zeus_llm::fetch_models`, but only 13 of the crate's arms have a live
    /// catalog, and the bridge folds the other ids to `Unsupported`. A screen
    /// that showed ONLY a list would leave those providers unarmable, which
    /// is the same defect the Ollama-only era had in a different costume. The
    /// list is an accelerator over the field, not a replacement for it.
    @State private var modelText: String = ""

    /// The catalog poll for the selected provider.
    ///
    /// Lives in the view because it is per-screen UI state, but every rule
    /// about it — which response wins, what an empty list means — is in
    /// `ModelPoll`, where it is testable without a view target.
    @State private var modelPoll = ModelPoll()

    /// The debounce task for key entry. Cancelled on every keystroke, so a
    /// paste that arrives one character at a time fires ONE request rather
    /// than one per character — each of which would be a live HTTP call from
    /// the operator's phone against a key that is not yet complete.
    @State private var pollTask: Task<Void, Never>? = nil

    /// The key the operator is typing, held in the view and NEVER in the
    /// record. `Commission` rides in `UserDefaults` precisely because it
    /// carries no secret (`CommissionStore.swift` docstring); this string is
    /// written to the Keychain by CONTINUE and to nothing else.
    @State private var keyText: String = ""
    /// The `url`-shape provider's endpoint. Empty is a real state: the CTA
    /// refuses it rather than substituting a default.
    @State private var baseURLText: String = ""

    /// Set once per appearance of ROUTES, from the core's own catalog.
    @State private var providerRows: [ProviderRow] = []

    /// The search text. VIEW STATE ONLY — never written to the record and
    /// never cleared by a tap, so a search that produced a choice still shows
    /// what was searched for; the operator can see WHY the list is short.
    @State private var providerQuery: String = ""


    var body: some View {
        let selected = providerPick.flatMap { id in providerRows.first { $0.id == id } }

        VStack(spacing: 10) {
            // SEARCH-FIRST: the field sits ABOVE the list because 26 rows
            // is past the point where scanning beats typing, and a search box
            // discovered after scrolling has already failed its purpose.
            TextField("", text: $providerQuery, prompt:
                Text("SEARCH PROVIDERS").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
            )
            .font(Theme.mono(13))
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.w(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .stroke(Theme.w(0.10), lineWidth: 1)
                    )
            )
            .accessibilityLabel("Search providers")

            ScrollView {
                VStack(spacing: 8) {
                    let groups = ProviderCatalog.grouped(providerRows, query: providerQuery)
                    // A QUERY THAT MATCHES NOTHING SAYS SO. An empty scroll
                    // view and a list still loading are the same pixels; the
                    // needle is echoed back so the operator can see what was
                    // actually searched for.
                    if groups.isEmpty && !providerRows.isEmpty {
                        Text("NO PROVIDER MATCHES \"\(providerQuery.uppercased())\"")
                            .font(Theme.mono(9))
                            .tracking(1.0)
                            .foregroundStyle(Theme.w(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    ForEach(groups, id: \.kind) { group in
                        Text(group.kind.header)
                            .font(Theme.mono(8.5))
                            .tracking(1.2)
                            .foregroundStyle(Theme.w(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    ForEach(group.rows, id: \.id) { row in
                        RouteCard(
                            title: row.label,
                            copy: row.shape.rowCopy,
                            selected: row.id == providerPick
                        ) {
                            // A key typed for one provider is not a key for
                            // another: switching rows clears the field, and the
                            // OLD provider's stored key is removed so a
                            // half-finished choice leaves no orphan secret.
                            if let previous = providerPick, previous != row.id {
                                keyText = ""
                                baseURLText = ""
                                keys.removeProviderKey(for: previous)
                            }
                            providerPick = row.id
                            // The typed model does not survive a provider
                            // switch: `gpt-4o` under Anthropic is a name no
                            // provider serves, and the CTA would happily
                            // write it.
                            modelText = ""
                            pollTask?.cancel()
                            modelPoll.reset()
                            startPoll(for: row)
                        }
                    }
                    }
                }
            }
            .frame(maxHeight: 260)

            if let selected {
                TextField("", text: $modelText, prompt:
                    Text("MODEL").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
                )
                .font(Theme.mono(13))
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .fill(Theme.w(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.corner)
                                .stroke(Theme.w(0.10), lineWidth: 1)
                        )
                )
                .accessibilityLabel("Model for \(selected.label)")

                // THE LIST IS AN ACCELERATOR OVER THE FIELD, NEVER A
                // REPLACEMENT. It appears only in `.listed`, and tapping a row
                // fills the same `modelText` the operator could have typed —
                // so there is exactly ONE value the CTA reads, and "picked"
                // and "typed" cannot drift into two sources.
                if !modelPoll.offeredModels.isEmpty {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(modelPoll.offeredModels, id: \.self) { name in
                                Button {
                                    modelText = name
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(name)
                                            .font(Theme.mono(11))
                                            .foregroundStyle(name == modelText
                                                             ? Theme.accent
                                                             : Theme.w(0.75))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        if name == modelText {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(Theme.accent)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.barCorner)
                                            .fill(Theme.w(name == modelText ? 0.06 : 0.02))
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Model \(name)")
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }

                if let note = modelPoll.statusLine {
                    Text(note)
                        .font(Theme.mono(8.5))
                        .tracking(1.0)
                        .foregroundStyle(Theme.w(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if case .key = selected.shape {
                    keyField(for: selected)
                }
                if case .url = selected.shape {
                    baseURLField(for: selected)
                }
                if case let .unsupported(reason) = selected.shape {
                    Text("\(selected.label.uppercased()) CANNOT BE SET FROM THIS SCREEN — \(reason.uppercased())")
                        .font(Theme.mono(8.5))
                        .tracking(1.0)
                        .foregroundStyle(Theme.w(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            do {
                // The hint is part of the contract: the key field here is
                // not the only place keys can be added.
                Text("MORE ROUTES ANYTIME IN NODES → ROUTE")
                    .font(Theme.mono(8.5))
                    .tracking(1.0)
                    .foregroundStyle(Theme.w(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            // The CTA is disabled until BOTH halves are answered, because the
            // record it writes has no representable "partly chosen" state.
            PrimaryButton(ctaTitle, glyph: "arrow.right") {
                guard let id = providerPick else { return }
                let typed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !typed.isEmpty else { return }
                // THE CHOICE GOES UP, IT IS NOT WRITTEN HERE. The three values
                // are the operator's; what a caller does with them differs by
                // caller — onboarding advances a step, the NODES sheet closes
                // and re-arms the core — and a component that performed one of
                // those itself would be narrating an act it cannot see the end
                // of. `Commission.provider` is `String?` and nil means nobody
                // chose; nothing in this file names a provider.
                onCommit(id, typed, baseURLText)
                // THE SECRET GOES TO THE KEYCHAIN, NOT TO THE RECORD, and it
                // goes AFTER the commit for the same reason it used to go
                // after the record write: a key must never be stored for a
                // provider the caller did not take.
                let secret = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !secret.isEmpty { keys.setProviderKey(secret, for: id) }
            }
            .disabled(!Self.routesCTAEnabled(providerPick: providerPick,
                                             modelText: modelText,
                                             shape: selected?.shape,
                                             baseURLText: baseURLText))
        }
        .onAppear {
            providerRows = ProviderCatalog.current.rows()
            // CAPTURE SEAM. Writes the same two `@State` fields a tap and a
            // keystroke write, and nothing else — no record write, no key.
            // Inert unless `-zeusPick` is passed, and `LaunchArgs.pickedRoute`
            // is `nil` in release, so this is a no-op in a shipped build.
            //
            // Guarded on `providerPick == nil` so a re-appearance of ROUTES
            // (backstep, then forward again) cannot stomp a choice the
            // operator has since made by hand.
            if providerPick == nil, let seed = LaunchArgs.pickedRoute {
                providerPick = seed.id
                if let m = seed.model { modelText = m }
            }
        }
    }

    /// EXTRACTED BECAUSE THE VIEW BODY IS NOT OBSERVABLE IN THIS TARGET.
    ///
    /// Measured: replacing the CTA's `.disabled(...)` with `.disabled(false)`
    /// left all 424 tests green — a SwiftUI modifier inside a `body` has no
    /// importable surface, so the gate had no guard at all. As a static
    /// function over its two inputs it does.
    ///
    /// BOTH halves are required because the record has no representable
    /// "partly chosen" state: `recordRoutesChoice` writes provider AND model
    /// together, and a CTA that fired on one of them would write a commission
    /// whose other half the operator never gave.
    static func routesCTAEnabled(providerPick: String?,
                                 modelText: String,
                                 shape: CredentialKind?,
                                 baseURLText: String) -> Bool {
        guard providerPick != nil else { return false }
        guard !modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A `.url` provider with no URL is the one shape that can pass every
        // other gate and still be unarmable: the id is chosen, a model may be
        // typed by hand, and only the endpoint is missing. Refusing here is
        // what makes `CoreArming.arm`'s NO URL arm unreachable in practice
        // rather than a screen the operator meets after commissioning.
        if case .url = shape {
            return !baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// The endpoint field for a `.url`-shape provider.
    ///
    /// `TextField`, not `SecureField`: this is an address, not a credential,
    /// and masking it would hide a typo in the one value the operator has to
    /// get exactly right.
    ///
    /// `http://localhost:11434` is the PROMPT and never the VALUE. A prefilled
    /// value is the bridge's hardcoded default moved up one layer wearing the
    /// operator's name — it would be written to the record as though he had
    /// chosen it, and on a phone it points at the phone. As a prompt it is
    /// discoverable and still has to be owned.
    private func baseURLField(for row: ProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ENDPOINT")
                .font(Theme.mono(9))
                .tracking(1.4)
                .foregroundStyle(Theme.w(0.35))
            TextField("", text: $baseURLText, prompt:
                Text("http://localhost:11434").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
            )
            .font(Theme.mono(13))
            .foregroundStyle(Theme.w(0.92))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.URL)
            // A `.url` provider's catalog is unreachable until the endpoint
            // is typed — on a phone `localhost` is the phone, which is why
            // the bridge refuses a nil base URL rather than defaulting.
            .onChange(of: baseURLText) { _, _ in
                schedulePoll(for: row)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.w(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .stroke(Theme.w(0.10), lineWidth: 1)
                    )
            )
            .accessibilityLabel("Endpoint for \(row.label)")
        }
    }

    /// The key field. Collectable now; it was inert until the provider-scoped
    /// Keychain landed, and the copy said so.
    ///
    /// `SecureField` rather than `TextField`: the value is a secret, and the
    /// difference is not cosmetic — an unmasked field is readable over a
    /// shoulder and is offered to the keyboard's learning cache.
    // MARK: - Model catalog polling

    /// Debounce window for key/endpoint entry, in nanoseconds.
    ///
    /// Named rather than inlined because it is a POLICY — how long the
    /// operator may pause mid-paste before we spend a network call — and a
    /// magic number inside a `Task.sleep` is a policy nobody can find.
    private static let pollDebounce: UInt64 = 450_000_000

    /// Cancel any pending poll and schedule a fresh one.
    private func schedulePoll(for row: ProviderRow) {
        pollTask?.cancel()
        // The RESET is not cosmetic: it bumps the generation, so a request
        // already in flight for the previous key text is stale on arrival
        // rather than landing under the new key's name.
        modelPoll.reset()
        pollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.pollDebounce)
            if Task.isCancelled { return }
            startPoll(for: row)
        }
    }

    /// Ask the core for this provider's catalog, if it is askable at all.
    ///
    /// Returns without asking when the shape's precondition is unmet — a
    /// `.key` provider with no key, a `.url` provider with no endpoint. That
    /// is `.idle`, NOT `.unavailable`: "we have not asked" and "we asked and
    /// could not get an answer" are different states, and rendering an empty
    /// key field as `COULDN'T REACH` would blame the network for a field the
    /// operator has simply not filled in yet.
    private func startPoll(for row: ProviderRow) {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .key = row.shape, key.isEmpty {
            modelPoll.reset()
            return
        }
        if case .url = row.shape, url.isEmpty {
            modelPoll.reset()
            return
        }
        if case .unsupported = row.shape {
            modelPoll.reset()
            return
        }
        guard let core = EmbeddedCapabilities.shared() else {
            modelPoll.reset()
            return
        }
        let token = modelPoll.begin()
        let probeKey = CoreArming.probeKey(for: row.id, typed: key)
        let baseURL = url.isEmpty ? nil : url
        Task { @MainActor in
            // `listModels` is a BLOCKING FFI call — it drives a Tokio runtime
            // inside the bridge and returns when the HTTP round trip does.
            // Running it on the main actor would freeze the screen for the
            // length of the request, which is exactly the interval
            // `FETCHING MODELS…` exists to make visible rather than to make
            // felt.
            let result: Result<[String], Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try core.listModels(id: row.id, key: probeKey, baseURL: baseURL)) }
                catch { return .failure(error) }
            }.value
            modelPoll.accept(result, generation: token, label: row.label)
            // A SINGLE-MODEL CATALOG FILLS THE FIELD; a multi-model one does
            // not. Choosing for the operator when there is a choice is how a
            // picker silently repoints a route — the defect `Route.swift:284`
            // names one file over.
            if case let .listed(models) = modelPoll.state,
               models.count == 1, modelText.isEmpty {
                modelText = models[0]
            }
        }
    }

    private func keyField(for row: ProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API KEY")
                .font(Theme.mono(9))
                .tracking(1.4)
                .foregroundStyle(Theme.w(0.35))
            SecureField("", text: $keyText, prompt:
                Text("PASTE KEY").font(Theme.mono(12)).foregroundStyle(Theme.w(0.2))
            )
            .font(Theme.mono(13))
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            // THE KEY IS WHAT MAKES THE CATALOG ASKABLE, so entering it is
            // what triggers the poll. Debounced because a paste arrives as a
            // sequence of changes and each one would otherwise be a live HTTP
            // call from the phone against an incomplete key.
            .onChange(of: keyText) { _, _ in
                schedulePoll(for: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(Theme.w(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .stroke(Theme.w(0.10), lineWidth: 1)
                )
        )
        .accessibilityLabel("API key for \(row.label)")
    }
}
