import Foundation

/// C1 — the two dark core exports that can be wired WITHOUT a bridge rebuild:
/// `remember(fact:)` and `search(query:)`.
///
/// ── Why this file is pure and the views are not ──────────────────────────
///
/// A SwiftUI `var body` has no importable surface from the test target — the
/// same measured reason `ProviderCatalog.grouped` and `routesCTAEnabled` were
/// extracted. Every decision C1 makes (what string gets remembered, what the
/// operator is told, what a zero-hit search MEANS) lives here as a function of
/// its inputs, so the legs assert the decision rather than a screenshot.
///
/// ── The naming decision, and why it CHANGED ─────────────────────────────
///
/// C1 shipped this surface as `FIND A FILE`, and that was the honest label
/// at the time. Walked at pin `2bfc08aa`:
///
///   bridge:496   index.add(FileEntry::new(&rel, name, meta.len()))
///   with_first_line / with_tags call sites in the bridge = 0  (POS: add = 1)
///
/// `FileIndex` weights name 3.0, tags 2.0, first_line 1.0 — both lower tiers
/// were structurally empty, so every posting came from a FILE NAME. A fact
/// written by `remember` lands INSIDE `memory/MEMORY.md`, whose name never
/// changes, and was therefore unfindable — permanently, not until relaunch.
/// Labelling that "memory search" would have built a screen where you type
/// the thing you just saved and get nothing back.
///
/// `d5619c8` closed both halves: `scan_workspace` now reads each text file
/// (bounded 64 KiB, NUL-rejected) and feeds de-duplicated word tokens to
/// `with_tags` (weight 2.0), and `remember` re-indexes so a fact is findable
/// WITHOUT a relaunch. Zeus100's host probe is the receipt:
/// `remember("zebraquorum …")` → `search("zebraquorum")` was 0 hits before,
/// 1 hit after.
///
/// So the label is now `MEMORY SEARCH`, and `testTheLabelIsBackedByTheRust`
/// is what keeps that sentence true: it reads the bridge source and asserts
/// `with_tags` is CALLED. Re-pin the bridge to a sha without content tokens
/// and the leg reds — the label cannot drift back into a lie silently. Note
/// what it does NOT assert: `with_first_line` stays uncalled on purpose
/// (`indexer.rs:213-221` does not de-duplicate that tier, so a file
/// repeating one word 500 times would outrank the file NAMED for it), which
/// is why the 1.0 tier is still empty and `SearchHit.context` is still nil.
enum Recall {

    // MARK: - remember

    /// What actually gets written, or `nil` if there is nothing to write.
    ///
    /// The core appends `\n- [ts] fact` to `memory/MEMORY.md` verbatim, so a
    /// newline inside the fact would forge a SECOND bullet with no timestamp —
    /// one call producing two entries, the later one undated. Newlines are
    /// folded to spaces rather than rejected, because the subject here is a
    /// transcript bubble and multi-line replies are the common case, not the
    /// edge.
    ///
    /// The cap is on the WRITE, not on the display: `MEMORY.md` is re-read in
    /// full by every recall, so an unbounded paste is a cost paid on every
    /// future turn rather than once here.
    static func factToWrite(from raw: String) -> String? {
        let folded = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let squeezed = folded
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !squeezed.isEmpty else { return nil }
        guard squeezed.count > factCap else { return squeezed }
        return String(squeezed.prefix(factCap)) + "…"
    }

    /// 600 characters. Not a round number chosen for looks: `MEMORY.md` is the
    /// file `search` indexes and every recall reads, and the scaffolding file
    /// it is appended to ships at well under a kilobyte.
    static let factCap = 600

    /// What the operator is told. Three arms, because three things can happen
    /// and a single "SAVED" would report the same success for all of them.
    enum RememberOutcome: Equatable {
        /// The core took it.
        case written
        /// There was no core to ask — `EmbeddedCore.shared` failed to init.
        case noCore
        /// The bubble held nothing writable.
        case empty
        /// The core raised. The message is the core's, not ours.
        case failed(String)
    }

    static func rememberToast(_ outcome: RememberOutcome) -> String {
        switch outcome {
        // MIGRATED, not pinned. The first draft of this line carried a literal
        // `\u{00A0}·\u{00A0}` and `check_separator_debt.sh` went red on it as a
        // NEW site — which is the case the set-pin was cut for two commits ago,
        // firing on its author. `Theme.joined` is the migrated form: it owns the
        // separator and the W1 wrap rule with it.
        case .written:          return Theme.joined(["MEMORY WRITTEN", "THIS DEVICE"])
        case .noCore:           return "NO CORE ON THIS DEVICE — NOTHING TO WRITE TO"
        case .empty:            return "NOTHING TO REMEMBER"
        case .failed(let why):  return "MEMORY WRITE FAILED — \(why.uppercased())"
        }
    }

    // MARK: - find (the file index)

    /// The query the core is actually asked, or `nil` if the field holds
    /// nothing to ask with.
    ///
    /// Whitespace-only is `nil` and NOT an empty-string call: `FileIndex`
    /// tokenises the query, so `""` scores nothing and returns `[]` — which
    /// renders identically to "searched and found nothing". A field the user
    /// has not filled in is not a search that failed.
    static func queryToRun(from raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// What the results area says, over (has the user asked, what came back,
    /// how big is the index).
    ///
    /// `indexSize` is in the signature for exactly one reason and it is the
    /// reason that export exists — its own doc calls it "a vacuity probe, not
    /// a statistic." Zero hits over an EMPTY index and zero hits over a
    /// populated one are different facts: the first says the core indexed
    /// nothing, the second says your term is not in the five files it has.
    /// Folded together, a broken scan is indistinguishable from a bad query.
    static func findSummary(query: String?,
                            hitCount: Int,
                            indexSize: UInt32?) -> String {
        guard let indexSize else { return "NO CORE" }
        guard query != nil else {
            return indexSize == 0
                ? "INDEX EMPTY"
                : "\(indexSize) FILES INDEXED"
        }
        if indexSize == 0 { return "INDEX EMPTY — NOTHING TO SEARCH" }
        if hitCount == 0  { return "NO MATCH IN \(indexSize) FILES" }
        return "\(hitCount) OF \(indexSize) FILES"
    }

    /// The row's trailing slot: the score, fixed to two places.
    ///
    /// Rendered because it is the only thing distinguishing a strong name hit
    /// from a weak one, and the whole index is name tokens — without it, two
    /// rows that matched very differently look identical.
    static func scoreLabel(_ score: Double) -> String {
        String(format: "%.2f", score)
    }

    /// The directory portion of a hit's path, or `nil` at the root.
    ///
    /// The row already renders `name`; repeating it inside the path would
    /// spend the value slot on a string the operator is already reading.
    static func dirLabel(for path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }
}
