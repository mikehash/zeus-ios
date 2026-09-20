import Foundation

/// An image the operator picked, on its way to the vision channel.
///
/// APP-OWNED, not the FFI `ImageAttachment`, and the reason is a boundary
/// question rather than taste. `SessionTransport` is the app's own protocol
/// with four production conformers, and one of them — `HTTPTransport` — can
/// never construct a vision payload at all: the gateway's `/v1/chat` wire has
/// no image field. Typing the protocol on a uniffi-GENERATED record would make
/// every bridge regeneration a potential twelve-conformer signature change,
/// and would force the refusing conformer to import a type it exists to
/// decline. Same reason `SessionRow` and `RecallHit` are app types: the app
/// owns a seam precisely when one conformer cannot satisfy it.
///
/// The FFI crossing therefore happens at exactly ONE site —
/// `EmbeddedTransport`, where `core.send(images:)` is actually called. That is
/// the same line that carried the hardcoded `images: []`, so the mapping and
/// the removal of the empty literal are the same edit.
struct OutboundImage: Equatable {
    /// The mime the SYSTEM's UTI table named for this file, already judged an
    /// image by the core's own `is_image` predicate across the bridge. Not
    /// re-checked here: a second opinion in Swift is the allow-list the arc
    /// banned, wearing a struct.
    let mimeType: String

    /// The whole file. Bytes ride IN BAND on the model wire — an image is the
    /// one attachment kind that is not staged to the workspace, because there
    /// is no `read_file` call that could make a PNG legible.
    let bytes: Data
}

/// What the composer is carrying into the next turn.
///
/// Two kinds with genuinely different destinations, which is why this is an
/// enum and not the `String?` path it replaced. A document becomes a workspace
/// path the model opens with `read_file` — the reference is TEXT in the turn.
/// An image becomes bytes on the wire — nothing goes in the text at all. The
/// old `stagedPath: String?` could express only the first, so an image had
/// either to lie about a path that does not exist or be dropped.
enum OutboundAttachment: Equatable {
    /// Staged into the workspace. The payload is the RELATIVE path
    /// `attachmentReference` builds the marker from.
    case staged(String)

    /// Held for the vision channel. Carries the file name only so the composer
    /// can NAME what is attached; the name never reaches the model, because
    /// the bytes are the message.
    case image(OutboundImage, name: String)

    /// The path a staged document contributes to the turn text, or `nil`.
    ///
    /// 🔴 THE REGRESSION SURFACE OF THE SHIPPING HALF. `turnText` is unchanged
    /// and still takes a `String?`, so the document route composes the exact
    /// same sentence it did before this cut. An image yields `nil` here — it
    /// must not add a reference line, because there is no staged path to
    /// reference and a marker naming a file the workspace does not contain
    /// would send `read_file` after nothing.
    var stagedPath: String? {
        switch self {
        case .staged(let rel): return rel
        case .image: return nil
        }
    }

    /// The images this attachment contributes to the turn, in transport shape.
    ///
    /// Empty for a document — not because images are absent by default, but
    /// because a staged document has none BY CONSTRUCTION. The distinction
    /// matters: the empty literal that used to live at `EmbeddedTransport` was
    /// a value nothing could change, and this one is an arm of an exhaustive
    /// switch.
    var images: [OutboundImage] {
        switch self {
        case .staged: return []
        case .image(let img, _): return [img]
        }
    }

    /// The line above the composer. Same shape for both kinds so the operator
    /// reads one sentence, but an image says what it IS — a document that
    /// claimed to be staged when it was held in memory would be the locality
    /// costume one surface over.
    func line(armed: Bool) -> String {
        switch self {
        case .staged(let rel):
            return SessionView.stagedLine(path: rel, armed: armed)
        case .image(let img, let name):
            return Theme.joined(["ATTACHED", name.uppercased(),
                                 img.mimeType.uppercased(),
                                 armed ? "SENDS WITH NEXT MESSAGE"
                                       : "PENDING — NO PROVIDER ARMED"])
        }
    }
}
