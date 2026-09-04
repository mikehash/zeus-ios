import Foundation

/// `zeus://` URL routing.
///
/// ## Scope, stated before the code, because a deep link is a promise
///
/// A deep link is a claim that the app can put the user somewhere. This
/// parser is deliberately narrow: it resolves ONLY destinations the app can
/// actually reach today — the three tabs, plus a session prompt prefill.
///
/// It does NOT parse a node id (`NodesView` has no per-node detail route to
/// land on), and it does NOT parse a session id (the engine names its own
/// session from the gateway; there is no "open session X" surface to honour).
/// Accepting those URLs and dropping them on the floor would be the
/// `t-12min` defect in link form: an input shaped like a working feature,
/// with nothing behind it. Better to refuse and be legible.
///
/// ## The refusal rule
///
/// An unrecognised link returns `nil`. It does NOT fall back to `.zeus`, or
/// to any tab. A fallback would navigate the user *somewhere* on a malformed
/// URL and look like success — a confident destination with no source. The
/// caller's job on `nil` is to do nothing.
enum DeepLink: Equatable {
    /// Navigate to a tab, with no further action.
    case tab(Tab)

    /// Navigate to SESSION and prefill the composer with `prompt`.
    ///
    /// Prefill, NOT send. A URL that could make the app talk to the gateway
    /// without a human pressing anything is a surface any web page could
    /// fire. The user gets a filled field and an explicit send.
    case session(prompt: String)

    /// The scheme this app answers to, matched case-INSENSITIVELY.
    ///
    /// RFC 3986 §3.1 defines schemes as case-insensitive, and iOS will hand
    /// us whatever the sender typed — `ZEUS://nodes` from an email client is
    /// a legal spelling of the same link. `URL.scheme` does not normalise it.
    static let scheme = "zeus"

    /// Parse a URL into a destination, or refuse.
    ///
    /// Every refusal arm is deliberate; see the doc comment on each guard.
    static func parse(_ url: URL) -> DeepLink? {
        // ① Scheme. Case-insensitive per RFC 3986; a foreign scheme is not
        //    ours to interpret even if the rest of the URL looks right.
        guard let s = url.scheme?.lowercased(), s == scheme else { return nil }

        // ② Host is the destination. `URLComponents` is used rather than
        //    `url.host` because the query has to come from the same parse —
        //    reading host from one API and query from another is two parses
        //    of one string, and they can disagree on a malformed input.
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // A bare `zeus://` has no host at all. Nothing to route to.
        guard let rawHost = comps.host, !rawHost.isEmpty else { return nil }

        // ③ Tab lookup. `Tab`'s raw values are lowercase, and hosts are
        //    case-insensitive in the same clause of RFC 3986 that covers
        //    schemes, so `zeus://SESSION` must resolve.
        //
        //    An unknown host refuses here — this is the no-fallback rule.
        guard let tab = Tab(rawValue: rawHost.lowercased()) else { return nil }

        // ④ Prompt, only meaningful on SESSION. A `?prompt=` on `zeus://nodes`
        //    is silently ignored rather than honoured, because there is no
        //    composer on that tab to prefill — honouring it would require
        //    navigating somewhere the URL did not ask for.
        guard tab == .session, let prompt = promptValue(comps) else {
            return .tab(tab)
        }

        return .session(prompt: prompt)
    }

    /// Extract `?prompt=`, folding empty to absent.
    ///
    /// THREE STATES, not two: no `prompt` key, `prompt` present but empty,
    /// and `prompt` with content. The first two are the same destination —
    /// `.tab(.session)` with an untouched composer. Returning `""` here
    /// would prefill the field with nothing and mark it dirty, which is
    /// visibly different from not having been asked to prefill at all.
    private static func promptValue(_ comps: URLComponents) -> String? {
        guard let items = comps.queryItems else { return nil }

        // `first(where:)` and not a dictionary fold: a duplicated key
        // (`?prompt=a&prompt=b`) has no defined meaning, and taking the first
        // is at least a stated rule rather than dictionary-insertion order.
        guard let raw = items.first(where: { $0.name == "prompt" })?.value else {
            return nil
        }

        // `URLComponents` percent-decodes but does NOT decode `+` as a space
        // — that convention is `application/x-www-form-urlencoded`, not RFC
        // 3986, and a URL typed by a human ("zeus://session?prompt=hello+zeus")
        // uses it constantly. Decoding it here is a deliberate choice to
        // favour the human speller over the spec, and it is the only
        // transformation applied.
        let decoded = raw.replacingOccurrences(of: "+", with: " ")

        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
