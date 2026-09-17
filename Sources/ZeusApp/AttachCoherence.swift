import Foundation

/// Whether a picked file was fully here, and whether what we read agrees with
/// what the provider said was there.
///
/// ## What this guarantees, scoped at the boundary
///
/// **Materialised-and-coherent against a non-adversarial, eventually-consistent
/// provider.** Never "complete".
///
/// It catches INCOHERENT truncation — the common case, a partially materialised
/// ubiquitous item, or a streaming provider extension that returns early. It is
/// BLIND to COHERENT truncation, where the provider under-reports the declared
/// total and short-reads the bytes in agreement with itself. Status, declared
/// size and bytes all come from the ONE provider; two questions to one source
/// is a consistency instrument, and an independent witness would need a
/// different SOURCE, which an app sandbox reading a file provider does not
/// have. That is the boundary of the position, not a gap in the design — and
/// naming it correctly is the guard against trusting it past its reach.
///
/// ## Why this file knows nothing about `URL`
///
/// 🔴 `declaredTotal` arrives as a PARAMETER, never read inline from the URL.
/// Inline, the assert would read a value the simulator never makes short, so
/// the failing red would be UNWRITABLE BY CONSTRUCTION — the same tautology
/// class as `written.starts_with(root.join(x))`, which shipped green and
/// unfalsifiable one arc ago. At a seam taking `(declaredTotal, stagedCount)`
/// the red is trivial: `(4096, 512)` → refuse.
///
/// So the absence of `URL` and `resourceValues` tokens in this file is not
/// tidiness, it is the guard: re-inlining the size read would have to put a URL
/// read HERE, and a census leg reds on exactly that.
enum AttachCoherence {

    /// What a precondition or post-condition decided.
    ///
    /// The refusal arm carries the sentence the operator READS, for the same
    /// reason `StageOutcome.failed` does: no layer between the refusal and what
    /// is on screen.
    enum Verdict: Equatable {
        case ok
        case refuse(String)

        var isOK: Bool { self == .ok }
    }

    /// (a) STATUS PRECONDITION — is the file fully here before we read it?
    ///
    /// `NSMetadataUbiquitousItemDownloadingStatusCurrent` is a MATERIALISATION
    /// predicate rather than a QUANTITY comparison, which is why it does not
    /// inherit the era-dependence that makes a size comparison alone unsafe: a
    /// dataless APFS placeholder reports the declared LOGICAL size (a size
    /// check works), while a legacy `.icloud` stub is a different, small file
    /// whose size is the STUB's (a size check becomes a tautology after a short
    /// read of the stub). Same resource key, opposite semantics, decided by the
    /// provider extension. Refusing anything not `.current` puts that fork out
    /// of reach.
    ///
    /// A different AXIS, the SAME respondent. This widens the aperture; it does
    /// not create a second witness.
    ///
    /// `nil` → OK. A plain on-device file is not a ubiquitous item and has no
    /// downloading status; refusing there would break every ordinary pick,
    /// which is most of them.
    static func materialisation(downloadingStatus: String?) -> Verdict {
        guard let status = downloadingStatus else { return .ok }
        if status == URLUbiquitousItemDownloadingStatus.current.rawValue { return .ok }
        // NAMES THE FIX. A refusal that only reports a state leaves the
        // operator with a dead control and no next move; "OPEN IT IN FILES
        // FIRST" is an instruction. The same rule the disarm and attach
        // reasons follow one screen over.
        return .refuse("THAT FILE IS NOT DOWNLOADED — OPEN IT IN FILES FIRST")
    }

    /// (c) COHERENCE POST-CONDITION — does what we read agree with what was
    /// declared?
    ///
    /// Runs AFTER the coordinated read, on the count actually staged. Called a
    /// COHERENCE check and not a completeness check on purpose: see the type
    /// note. It can only ever catch the provider contradicting itself.
    ///
    /// `declaredTotal == nil` → OK. A non-ubiquitous file has no declared
    /// total, and a guard that refused on a missing number would refuse the
    /// common case.
    ///
    /// Short REFUSES. Over is also incoherent but the bytes are not a fragment,
    /// so it is not the defect this arc exists to close and refusing it would
    /// trade a real capability for a number nobody reads; the comparison is
    /// `<`, deliberately, and the doc says so rather than the reader having to
    /// infer it from the operator.
    static func coherence(declaredTotal: Int?, stagedCount: Int) -> Verdict {
        guard let total = declaredTotal else { return .ok }
        guard stagedCount < total else { return .ok }
        return .refuse(shortReadLine(staged: stagedCount, declared: total))
    }

    /// What a short read says.
    ///
    /// Shown as honestly as the empty guard, and with the NUMBERS, because
    /// "STAGING FAILED" over a truncation is the fabricated-toast defect with a
    /// true filename attached: the operator cannot tell a broken app from a
    /// half-arrived file, and those send them to different places.
    ///
    /// Built through `Theme.joined` rather than a retyped separator —
    /// `check_separator_debt` caught the literal form before and was right;
    /// `Theme.separator` is NBSP-padded, so a hand-typed `·` renders a
    /// different glyph pair than every other strip on the screen.
    static func shortReadLine(staged: Int, declared: Int) -> String {
        Theme.joined(["FILE ARRIVED INCOMPLETE",
                      "\(staged) OF \(declared) BYTES",
                      "NOTHING STAGED"])
    }
}
