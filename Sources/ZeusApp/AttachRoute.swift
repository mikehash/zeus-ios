import Foundation

/// Where a picked file goes, decided ONCE, in a symbol a test can call.
///
/// The decision used to live inline in `RootView.stage(_:)` — a `private func`
/// on a view, which is the shape that made the bridge's `is_image` gate
/// structurally unreachable one arc ago: the whole suite stayed green under a
/// mutation that deleted it. A guard whose only caller is a private view body
/// is a guard no leg can be the caller of. Extracted, it has one.
///
/// This type does NOT classify. `classifyAttachment` does, across the bridge,
/// using the core's own predicates. This maps a kind to a DISPOSITION, which
/// is the honesty question: what does the operator see when we cannot carry
/// their file.
enum AttachRoute {
    /// `nil` means "proceed to the stage". A value means "refuse, and this is
    /// the sentence" — `StageOutcome.failed` renders verbatim with no fault
    /// envelope, which is why the strings are built here and not composed by a
    /// caller that might wrap them.
    static func refusal(for kind: AttachmentKind) -> String? {
        switch kind {
        case .image(let mimeType):
            // HONEST, not silent. The vision channel exists at the bridge door
            // (`send(images:)`); nothing in Swift can reach it, because
            // `SessionTransport.stream` carries prose only. Staging a PNG
            // would hand `read_file` a binary the model reads as garbage while
            // the transcript claims the file was attached — the silent drop
            // this whole arc exists to retire. Named, with the reason.
            return Theme.joined(["\(mimeType.uppercased()) NEEDS THE VISION CHANNEL",
                                 "NOT WIRED ON THIS BUILD YET"])
        case .unsupported(let reason):
            // The subject is NAMED: the extension when there is one, the file
            // name when there is not. "UNSUPPORTED FILE" with no subject is a
            // refusal the operator cannot act on.
            return Theme.joined(["\(reason.uppercased()) ISN'T READABLE BY THE MODEL",
                                 "ATTACH TEXT, MARKDOWN OR A DOCUMENT"])
        case .document, .text:
            // Both stage. `read_file` extracts a document and returns text
            // verbatim, and the body arrives on the TOOL channel — data by
            // construction, never prompt text.
            return nil
        }
        // No `default:`. `AttachmentKind` is exhaustive across the bridge for
        // exactly this reason: a fifth kind must fail to compile HERE rather
        // than fall through to a silent stage.
    }
}
