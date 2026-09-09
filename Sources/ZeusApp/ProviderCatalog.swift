import Foundation

/// THE PROVIDER LIST IS THE CORE'S, NOT SWIFT'S.
///
/// Before this file the app named exactly one provider — a `String` constant
/// in the ROUTES step — and rendered it by upper-casing the WIRE ID, which is
/// Swift choosing a display form for a value it does not own (`xiaomimimo`
/// read as `XIAOMIMIMO` on the completion screen). `ProviderInfo.label` exists
/// precisely to prevent that, and `list_providers()` is a FREE function on the
/// bridge (`lib.rs:579`): no `Arc<Self>`, no live core, no workspace on disk.
/// So the catalog is readable from any surface, including a pure `Commission`
/// property, without threading a core handle through the record.
enum CredentialKind: Equatable {
    /// Nothing to collect (ambient OAuth).
    case none
    /// One API key. 21 of 26 providers.
    case key
    /// A URL, not a secret.
    case url
    /// Not collectable by this app's v1 form; `reason` is the core's own word.
    case unsupported(reason: String)

    init(_ shape: CredentialShape) {
        switch shape {
        case .none: self = .none
        case .key: self = .key
        case .url: self = .url
        case let .unsupported(reason): self = .unsupported(reason: reason)
        }
    }

    /// What the row says it will ask for. The ROW states the collectability;
    /// the FIELDS state whether this build can collect it yet. Two facts, two
    /// surfaces — a row that said "ready" over a disabled field would be the
    /// averaged form this cut exists to avoid.
    var rowCopy: String {
        switch self {
        case .none: return "Nothing to enter. The core signs in for you."
        case .key: return "One API key. It stays on this phone."
        case .url: return "A URL, not a secret. Points at your own daemon."
        case let .unsupported(reason): return "Not from this screen — \(reason)."
        }
    }
}

/// One provider the core knows: the id that is PERSISTED, the label that is
/// RENDERED, and what the row would collect.
struct ProviderRow: Equatable {
    let id: String
    let label: String
    let shape: CredentialKind
}

protocol ProviderCataloging {
    func rows() -> [ProviderRow]
    /// The core's verdict for an id the app did not get from `rows()`.
    ///
    /// `credential_shape` THROWS on an unknown id (`zeus_core_bridge:1665`) —
    /// it never answers `.none` for one — so an id the core rejects must
    /// render AS an error. Nothing reachable today produces one (every row
    /// comes from the catalog), which is exactly why the arm is written now
    /// rather than after a core adds a variant this build has not seen.
    func shape(for id: String) -> CredentialKind
}

struct CoreProviderCatalog: ProviderCataloging {
    func rows() -> [ProviderRow] {
        listProviders().map {
            ProviderRow(id: $0.id, label: $0.label, shape: CredentialKind($0.shape))
        }
    }

    func shape(for id: String) -> CredentialKind {
        guard let shape = try? credentialShape(id: id) else {
            return .unsupported(reason: "the core does not know this provider")
        }
        return CredentialKind(shape)
    }
}

enum ProviderCatalog {
    static var current: ProviderCataloging = CoreProviderCatalog()

    /// THE ONE PLACE A PROVIDER ID BECOMES WORDS.
    ///
    /// Falls back to the id VERBATIM — not upper-cased, not title-cased. An
    /// unknown id is a fact about the record, and dressing it up as a display
    /// name is the fabrication class this whole cut retires. Four surfaces
    /// call this: the summary strip and the three `CoreArming.armReason` arms.
    static func label(for id: String) -> String {
        current.rows().first { $0.id == id }?.label ?? id
    }
}

/// THE GROUPING KEY IS NOT `CredentialKind`.
///
/// `CredentialKind.unsupported` carries the core's own `reason` string, so two
/// unsupported providers with different reasons are `!=` and would land in two
/// different groups — a list that grows a section per sentence. The section is
/// a coarser fact than the row: WHAT WILL THIS ASK ME FOR, four answers, fixed
/// order. `CaseIterable` is load-bearing: the order below IS the rendered
/// order, and the `init(_:)` switch is exhaustive so a fifth `CredentialKind`
/// fails to compile here rather than silently vanishing from the picker.
enum ProviderGroupKind: String, CaseIterable, Equatable {
    case key
    case url
    case none
    case unsupported

    init(_ kind: CredentialKind) {
        switch kind {
        case .key: self = .key
        case .url: self = .url
        case .none: self = .none
        case .unsupported: self = .unsupported
        }
    }

    /// The section header. States the ASK, not the shape's name — `KEY` is a
    /// type, `NEEDS AN API KEY` is what the operator is about to do.
    var header: String {
        switch self {
        case .key: return "NEEDS AN API KEY"
        case .url: return "NEEDS AN ENDPOINT"
        case .none: return "NOTHING TO ENTER"
        case .unsupported: return "NOT FROM THIS SCREEN"
        }
    }
}

struct ProviderGroup: Equatable {
    let kind: ProviderGroupKind
    let rows: [ProviderRow]
}

extension ProviderCatalog {
    /// SEARCH-FIRST, GROUPED BY WHAT THE ROW WILL ASK FOR.
    ///
    /// Pure over (rows, query) because the view body has no importable
    /// surface in this target — the same reason `routesCTAEnabled` was
    /// extracted. Every property below is asserted against THIS function; the
    /// view is a `ForEach` over its output and holds no ordering logic of its
    /// own.
    ///
    /// - The query matches LABEL **or** ID, case- and diacritic-insensitively.
    ///   Id-matching is deliberate: the id is what gets PERSISTED and what the
    ///   arm messages name, so an operator who read `ollama` in an error must
    ///   be able to type it back. Matching only the label would make the one
    ///   string the app shows in failures unsearchable.
    /// - EMPTY GROUPS ARE DROPPED, not rendered empty. A `NOT FROM THIS
    ///   SCREEN` header over nothing is a claim that such providers exist in
    ///   this build.
    /// - RELATIVE ORDER WITHIN A GROUP IS THE CORE'S. No alphabetising and no
    ///   favourites — the catalog's order is a fact the app does not own, and
    ///   a "popular first" list is the hardcoded-preference class this whole
    ///   arc has been retiring.
    static func grouped(_ rows: [ProviderRow], query: String) -> [ProviderGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = needle.isEmpty ? rows : rows.filter { row in
            row.label.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || row.id.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return ProviderGroupKind.allCases.compactMap { kind in
            let members = matched.filter { ProviderGroupKind($0.shape) == kind }
            return members.isEmpty ? nil : ProviderGroup(kind: kind, rows: members)
        }
    }
}
