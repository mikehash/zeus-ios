import Foundation

/// The disposition of a picked attachment, decided ONCE for every source.
///
/// There are now two ways bytes enter this app — `.fileImporter` over a
/// security-scoped URL, and `PhotosPicker` over an out-of-process
/// `PhotosPickerItem` that has no URL at all. They differ in how the bytes are
/// OBTAINED and must not differ by one line in what happens NEXT: a photo that
/// skipped the classifier, or a document that skipped the image arm, is the
/// two-paths-one-fact drift this type exists to make impossible.
///
/// It takes an already-classified `kind` rather than calling
/// `classifyAttachment` itself. Not to avoid the bridge — to make this symbol
/// a pure function of its inputs, so a leg can BE its caller with no
/// xcframework loaded and no core on the machine. Classification stays where
/// the ruling put it: the core's own predicates, one crossing, at the caller.
enum AttachDoor {
    /// Map a classified pick to what the operator gets.
    ///
    /// `stage` is injected rather than reached for, and that is the leg-bearing
    /// part: an image must NEVER reach it. The document route works because the
    /// file becomes a workspace path `read_file` opens; vision is the opposite
    /// shape — bytes in band on the model wire, no file — so a PNG written to
    /// the workspace is a binary the model would read as garbage, and a test
    /// can now assert the closure went uncalled instead of asserting a comment.
    static func outcome(fileName: String,
                        bytes: Data,
                        kind: AttachmentKind,
                        stage: (String, Data) throws -> String) -> StageOutcome {
        guard !bytes.isEmpty else { return .failed("THAT FILE IS EMPTY — NOTHING STAGED") }

        if let why = AttachRoute.refusal(for: kind) {
            return .failed(why)
        }

        // The mime is the one the CORE already judged, taken out of the kind
        // rather than re-derived. Exactly one value decided "image", and it was
        // not ours.
        if case .image(let mimeType) = kind {
            return .attachedImage(OutboundImage(mimeType: mimeType, bytes: bytes),
                                  name: fileName)
        }

        do {
            return .staged(try stage(fileName, bytes))
        } catch {
            return .failed("STAGING FAILED — \(EmbeddedTransport.describe(error).uppercased())")
        }
    }
}
