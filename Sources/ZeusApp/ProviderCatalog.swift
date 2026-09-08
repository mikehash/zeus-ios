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
