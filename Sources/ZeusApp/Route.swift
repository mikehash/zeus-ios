import SwiftUI

/// A selectable inference route.
///
/// Transcribed from `prototypes/ZeusApp.jsx:322-331` (`const ROUTES`) at
/// `4798cc2` — the vendored SoT, so this citation is a sha and not a mtime.
///
/// ── WHAT IS DELIBERATELY NOT PORTED ─────────────────────────────────────
/// The prototype's rows carry a `meta` string: `P50 180MS · DIRECT`,
/// `P50 90MS`, `P50 320MS`. Those are **hardcoded literals in a mock**. This
/// app has no latency instrument — `grep -rn "p50\|latency" Sources` is 0 —
/// so rendering them would put a fabricated number in a slot the eye reads as
/// a measurement. That is the same defect class already burned out of this
/// tree three times (the literal status line, the literal link pill, the orb's
/// `level`), and a prototype's fingerprints on it do not make it a different
/// defect.
///
/// So `meta` is replaced by `reach` — a property of the route's TOPOLOGY,
/// which is knowable from the route's identity alone and needs no probe. If a
/// gateway ever reports real latency, it belongs beside `reach`, not instead
/// of it: one is measured, one is definitional, and collapsing them loses
/// which is which.
struct Route: Identifiable, Equatable {

    let id: String
    let name: String
    let reach: Reach

    /// How the request leaves this device. Definitional, not measured.
    enum Reach: String, Equatable, CaseIterable {
        /// Chosen per-request by the router; no fixed destination.
        case routed = "PER-REQUEST · COST/LATENCY AWARE"
        /// Straight to the provider over the internet.
        case direct = "DIRECT FROM THIS NODE"
        /// Never leaves the local network.
        case lanOnly = "LAN ONLY · NO EGRESS"
    }
}

enum RouteCatalog {

    /// The eight routes the prototype enumerates, in its order.
    ///
    /// ⚠️ THE PROTOTYPE CONTRADICTS ITSELF HERE AND THE CONTRADICTION IS NOT
    /// PORTED. `ZeusApp.jsx:769` renders the subtitle `11 PROVIDERS ENROLLED`
    /// directly above `ROUTES.map(...)` over an array of **eight**. The number
    /// is a literal in a mock; nothing computes it. Transcribing that string
    /// verbatim would ship a count that the list immediately below it refutes.
    ///
    /// `subtitle` therefore DERIVES the count from this array (see below), so
    /// the two can never disagree — and a route added or removed updates the
    /// header for free. The parity census at `275d3f4` recorded "11 routes"
    /// because it read the prototype's subtitle rather than its array; that row
    /// is corrected in the same commit as this file.
    static let all: [Route] = [
        Route(id: "auto",      name: "AUTO — NOUS ROUTES",        reach: .routed),
        Route(id: "anthropic", name: "ANTHROPIC · OPUS 4.6",      reach: .direct),
        Route(id: "openai",    name: "OPENAI · GPT-5.2",          reach: .direct),
        Route(id: "google",    name: "GOOGLE · GEMINI 3.1 PRO",   reach: .direct),
        Route(id: "xai",       name: "XAI · GROK 4.1",            reach: .direct),
        Route(id: "groq",      name: "GROQ · LLAMA 4 MAVERICK",   reach: .direct),
        Route(id: "deepseek",  name: "DEEPSEEK V4",               reach: .direct),
        Route(id: "ollama",    name: "OLLAMA · HOME NODE",        reach: .lanOnly),
    ]

    /// The default selection. `LOCAL · MLX` — the string the inert row carried
    /// at `NodesView:51` before this sheet existed — is NOT in the catalogue,
    /// so it cannot be the default without adding a ninth route that the
    /// prototype does not have. `ollama` is the nearest true statement: local,
    /// no egress.
    static let fallback = all.first { $0.id == "ollama" } ?? all[0]

    /// Derived, never literal. See the warning on `all`.
    static var subtitle: String { "\(all.count) PROVIDERS ENROLLED" }
}
