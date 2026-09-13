import Foundation

/// The app-owned session-list row — the seam's type, not the bridge's.
///
/// ── Why this type exists, measured at `482afc2a` ───────────────────────
///
/// The ruling was "the sort key becomes `Optional` at the `SessionCapabilities`
/// level; the gateway conformer returns `nil`". That sentence is not
/// expressible against `SessionInfo`:
///
/// ```
/// zeus_core_bridge.swift:1309   public var updatedAtRfc3339: String   ← UniFFI, non-Optional
/// ```
///
/// `SessionInfo` is GENERATED. There is no `nil` for a conformer to return,
/// and the three ways out are not equal:
///
///   (a) widen the bridge struct — touches `rust/`, moves the pin, and buys a
///       Rust-side change for a Swift-side fact. Rejected.
///   (b) have the gateway write `""` — it parses to `nil` and the comparator
///       does the right thing, so it WORKS. It is also the costume defect one
///       layer down: an empty string in a field named `updatedAtRfc3339` is a
///       claim that the session was updated at the empty instant, and
///       `History.ago` renders the raw string on unparseable, so the trailing
///       slot prints junk. Same shape as `created`-under-`updatedAt`, which
///       was already rejected once on this branch. Rejected.
///   (c) this file — an app-owned row at the seam, with the key Optional
///       BECAUSE THE FACT IS OPTIONAL, and each conformer mapping into it.
///
/// ── Why reshape now rather than later ──────────────────────────────────
///
/// The comparator, the view, the seam and the tests that read this type all
/// landed twenty minutes ago in `482afc2a`, and the consumer census is three
/// sites (`History.newestFirst`, `HistoryView:108`, `HistoryTests.info`). This
/// type is never cheaper to reshape than it is today, and every later commit
/// that decodes a remote session makes it dearer.
struct SessionRow: Equatable, Identifiable {

    /// The session id. Present on both paths — `GET /v1/sessions` emits `id`
    /// and the bridge's `SessionInfo` carries one.
    let id: String

    /// When this session was last written, RFC3339 — or `nil` when the backend
    /// cannot say.
    ///
    /// NOT a `String` with a sentinel. The embedded path reads `updated_at`
    /// off the session file and has a real answer. `GET /v1/sessions` emits
    /// `created` and no `updated` (`handlers/sessions.rs:69-71` at `8e19318c`,
    /// `"updated"` ×0 in that file), so the gateway has NO honest key to send —
    /// and a creation time under an update-time name would order the
    /// operator's history by the wrong fact while every leg stayed green,
    /// because both are valid RFC3339 and the field name does not care.
    ///
    /// `nil` means "this backend cannot rank these rows". `History.newestFirst`
    /// renders such rows in INPUT ORDER and the list header says `SERVER ORDER`
    /// — one statement of the fact, at the level where it is true. No per-row
    /// `UNKNOWN`, which would read as a parse failure of a key that was never
    /// sent.
    let sortKey: String?
}

extension SessionRow {

    /// The embedded mapping: the bridge always has a key, so it is always
    /// present. Written as a function rather than inline at the conformer so
    /// the two mappings sit next to their type and a reader can see that
    /// exactly one of them produces `nil`.
    init(_ info: SessionInfo) {
        self.init(id: info.id, sortKey: info.updatedAtRfc3339)
    }
}
