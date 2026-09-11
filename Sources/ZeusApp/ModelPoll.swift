import Foundation

/// The MODEL field's three honest states, and the staleness rule that keeps
/// them honest while the operator is still typing a key.
///
/// ## Why this is a value type and not a view
///
/// A SwiftUI body is not observable in this test target — the same aperture
/// `testTheRoutesCTACallsTheWriter` names one file over. Everything that can
/// be WRONG about polling (which result wins, what an empty list means, what
/// a refusal renders as, what happens when the provider changes mid-flight)
/// lives here, where a test can drive it. The view keeps exactly the part a
/// test could not reach anyway: a `Task.sleep` and two calls into this type.
///
/// ## The incident this exists for
///
/// Before the poll, `MODEL` was a bare `TextField` and `CoreArming.firstModel`
/// was called once on row tap. `list_models` was Ollama-only at that pin, so
/// for 25 of 26 providers the call returned a typed refusal, the arm handled
/// it silently, and the operator was left staring at an empty box with no
/// statement about why. The bridge now polls every provider
/// (`lib.rs list_models` delegating to `zeus_llm::fetch_models`), so the
/// screen can say which of the three things happened.
enum ModelListState: Equatable {
    /// Nothing asked yet — no provider chosen, or no key typed for a shape
    /// that needs one. NOT the same as "asked and got nothing".
    case idle
    /// A request is in flight. Rendered as `FETCHING MODELS…` so a slow
    /// network reads as slow rather than as empty.
    case fetching
    /// The provider answered with a catalog. Non-empty by construction —
    /// `accept` folds an empty vector into `.unavailable`, because the bridge
    /// already folds a live arm's empty list into `Unsupported` and a picker
    /// showing zero rows would claim the provider has no models when the
    /// truth is that we could not ask.
    case listed([String])
    /// We could not ask, or the asking failed. Carries the sentence the
    /// operator sees. The free-text field stays on screen in this state —
    /// 12 of 26 provider ids have no live catalog arm in the crate, and they
    /// must still be armable by typing.
    case unavailable(String)
}

/// A poll whose results are accepted by GENERATION, not by arrival.
///
/// ## The defect this shape prevents
///
/// Key entry fires a fetch per debounce window. The operator pastes a key,
/// deletes a character, pastes again — three requests, and nothing guarantees
/// the network returns them in order. Without a generation the LAST RESPONSE
/// wins; with one the LAST REQUEST wins. Those differ exactly when they
/// matter: a slow 401 for a half-typed key landing after a fast 200 for the
/// complete one would replace a real catalog with a refusal, and the operator
/// would see `COULDN'T REACH` for a key that works.
struct ModelPoll: Equatable {
    private(set) var state: ModelListState = .idle

    /// Monotonic. Never reset, including by `reset()` — a generation reused
    /// after a provider switch could be matched by an in-flight result from
    /// the PREVIOUS provider, which is the same wrong-subject the counter
    /// exists to prevent.
    private(set) var generation: Int = 0

    /// Open a request. The returned token must be handed back to `accept`.
    mutating func begin() -> Int {
        generation += 1
        state = .fetching
        return generation
    }

    /// Return to the un-asked state — provider changed, or the key was
    /// cleared. Bumps the generation so anything already in flight is stale
    /// on arrival rather than landing under the new provider's name.
    mutating func reset() {
        generation += 1
        state = .idle
    }

    /// Apply a result if it belongs to the newest request.
    ///
    /// - Returns: `true` when the result was applied, `false` when it was
    ///   dropped as stale. The boolean is returned rather than logged so a
    ///   test can assert the DROP, not just the absence of a change — an
    ///   assertion on state alone passes when two results happen to agree.
    @discardableResult
    mutating func accept(_ result: Result<[String], Error>,
                         generation token: Int,
                         label: String) -> Bool {
        guard token == generation else { return false }
        switch result {
        case let .success(models) where !models.isEmpty:
            state = .listed(models)
        case .success:
            // An empty vector reaching Swift means the bridge's fold did not
            // catch it. Rendering it as a zero-row picker would say "this
            // provider serves no models", which is a statement we have no
            // evidence for. Say the one we do.
            state = .unavailable(Self.unreachable(label))
        case let .failure(error):
            state = .unavailable(Self.refusal(error, label: label))
        }
        return true
    }

    /// The sentence for "we could not ask, or the ask failed".
    ///
    /// The crate's own text is specific — `zeus_llm::fetch_models` names the
    /// provider and the transport in its error, and `Unsupported` carries it
    /// verbatim through `describe`. But the operator's next action is the
    /// same in every one of those cases: type a model name. So the action is
    /// the headline and the diagnosis is not shown here; it is the same
    /// ruling `describe` makes for `NoBaseUrl`.
    static func unreachable(_ label: String) -> String {
        "COULDN'T REACH \(label.uppercased()) — TYPE A MODEL"
    }

    private static func refusal(_ error: Error, label: String) -> String {
        // `describe` renders `Unsupported` as the crate's sentence, which is
        // right for a transcript and wrong for a 46pt field. The label form
        // is used for every failure so the field never grows to fit a
        // stack trace.
        _ = EmbeddedTransport.describe(error)
        return unreachable(label)
    }
}

extension ModelPoll {
    /// Whether the MODEL field should be accompanied by a list.
    var offeredModels: [String] {
        if case let .listed(models) = state { return models }
        return []
    }

    /// The line under the field, or nil when there is nothing to say.
    ///
    /// `.listed` returns nil deliberately: the list itself is the statement,
    /// and a line repeating "5 MODELS" beside five visible rows is noise.
    ///
    /// NAMED `statusLine`, NOT `caption`. `check_narration_shape.sh` pins the
    /// number of `caption = ` sites in the tree, because a caption written
    /// outside `Narrator`'s reveal Task is a path by which the accessibility
    /// caption could come to depend on voice state. A `let caption =` binding
    /// here is not that — but it MATCHES the needle, and a guard whose subject
    /// is diluted by an unrelated word is a guard that gets its pin bumped
    /// until it means nothing. The guard was right; the name was the defect.
    var statusLine: String? {
        switch state {
        case .idle: return nil
        case .fetching: return "FETCHING MODELS…"
        case .listed: return nil
        case let .unavailable(message): return message
        }
    }
}
