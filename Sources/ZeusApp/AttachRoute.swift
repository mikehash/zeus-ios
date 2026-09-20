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
        case .image:
            // ROUTES NOW. The vision corridor exists end to end as of this
            // cut: `OutboundImage` from the door, through `StageOutcome`, the
            // composer, `send(_:images:)` and `stream(prompt:images:)`, to the
            // single FFI mapping at `EmbeddedTransport`. The refusal that used
            // to live here was honest about a wall that is gone; leaving it
            // would refuse a file the app can now carry.
            //
            // The transport that CANNOT carry it refuses at its own door
            // (`HTTPTransport`), because whether images travel is a property
            // of the wire in use, not of the file — and this function cannot
            // see which transport the turn will take.
            return nil

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
