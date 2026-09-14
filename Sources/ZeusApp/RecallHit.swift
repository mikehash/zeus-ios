import Foundation

/// A memory-search result AT THE SEAM — app-owned, with the kind of thing it
/// is as a discriminant rather than as an absent field.
///
/// ── Why an app-owned type and not `SearchHit` ──────────────────────────
///
/// `POST /v1/memory/search` has TWO response shapes, chosen by the gateway
/// according to whether Mnemosyne is available
/// (`zeus-api/handlers/memory_handlers.rs:512-530` vs `:601`):
///
/// ```
/// hybrid arm → { id, session_id, content, score, memory_type, importance }   NO path
/// file   arm → { path, snippet, score }
/// both       → "search_method": "hybrid" | "file"      (:530 / :558)
/// ```
///
/// The FFI `SearchHit` (`zeus_core_bridge.swift:1219`) declares
/// `public var path: String` — NON-optional, generated, so `path: Optional`
/// is not expressible without moving the bridge pin for a Swift-side fact.
/// The same wall `SessionInfo.updatedAtRfc3339` hit at S3a, and the same
/// answer: an app-owned row at the seam, mapped by each conformer.
///
/// Synthesising a `path` for a pathless record would be the costume defect —
/// a memory record wearing a file's clothes, the class the
/// `""`-under-`updatedAtRfc3339` sentinel was rejected for. So the kind is
/// structural: a `.memory` hit HAS no path field to fill in wrongly.
///
/// ── Why the decoder branches on fields, not on `search_method` ─────────
///
/// `search_method` is corroborating metadata, not the decision. A payload
/// whose entries carry `path` is a file hit whatever the method string says,
/// and a method string that disagreed with its own entries would otherwise
/// route a record to the file arm and blank its row.
struct RecallHit: Equatable, Identifiable {

    enum Kind: Equatable {
        /// A workspace file. `path` is the repo-relative path the gateway
        /// sent, or the bridge's own path on the embedded arm; `snippet` is
        /// the matching context, absent when neither arm supplied one.
        case file(path: String, snippet: String?)
        /// A Mnemosyne record. `memoryType` is the gateway's own
        /// `memory_type` string — rendered as the row's label, because a
        /// record has no name and a blank label is not a fact.
        case memory(id: String, memoryType: String, content: String)
    }

    let kind: Kind

    /// The ONE field genuinely shared by both wire arms, and therefore the one
    /// row slot that survives kind-agnostic (`NodesView:458`'s
    /// `Recall.scoreLabel`).
    let score: Double

    /// Stable within a result set. The file arm's path and the record arm's id
    /// are both unique per hit, which is why `id` can be derived rather than
    /// carried as a fourth field that could disagree with the kind.
    var id: String {
        switch kind {
        case let .file(path, _):      return "file:\(path)"
        case let .memory(id, _, _):   return "memory:\(id)"
        }
    }

    /// What the row's LABEL slot renders. File hits keep the leaf name — the
    /// row already spends its toast on the directory, so repeating the path
    /// here would spend two slots on one fact. Memory hits render their type.
    var label: String {
        switch kind {
        case let .file(path, _):
            return path.split(separator: "/").last.map(String.init) ?? path
        case let .memory(_, memoryType, _):
            return memoryType
        }
    }

    /// The SF Symbol. OFF THE KIND, never a literal: the render site carried
    /// `icon: "doc"` hardcoded, so every hit asserted "file" in a glyph
    /// before a single string was read — the costume defect in its purest
    /// form, and the one a reader sees first.
    var icon: String {
        switch kind {
        case .file:   return "doc"
        case .memory: return "brain"
        }
    }

    /// Whether this hit counts inside a FILES denominator.
    ///
    /// `Recall.findSummary` is FILES-denominated end to end (`N FILES
    /// INDEXED`, `NO MATCH IN N FILES`, `N OF M FILES`) and remotely
    /// `indexSize` is `GET /v1/memory/files` — doubly file-scoped, noun and
    /// measurement. A memory hit counted in that numerator is the costume one
    /// layer up from the row.
    var isFile: Bool {
        switch kind {
        case .file:   return true
        case .memory: return false
        }
    }
}

extension RecallHit {

    /// FFI `SearchHit` → `.file`, and ONLY `.file`.
    ///
    /// The embedded core searches `FileIndex`, which has no record arm at all
    /// (`scan_workspace` walks the workspace tree), so the embedded conformer
    /// cannot produce a `.memory` hit and must not pretend it might.
    ///
    /// `context` is the bridge's own Optional and passes through as `snippet`
    /// unchanged — an empty context and an absent one are the same fact here
    /// and neither invents a string.
    init(file hit: SearchHit) {
        self.kind = .file(path: hit.path, snippet: hit.context)
        self.score = hit.score
    }
}
