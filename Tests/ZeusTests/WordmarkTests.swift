import XCTest
@testable import Zeus

/// THE FOOTER'S GUARD, AND WHY `check_separator_debt.sh` COULD NOT BE IT.
///
/// The script is a literal census: it greps `Sources` for a bare `·` and
/// compares the site set to a pin. That instrument has exactly one blind
/// spot, and the Arc-D footer landed in it — once the text is built by
/// `Theme.joined` there is NO literal left to grep, so the script is green
/// on a tree where the footer was deleted, renamed, or duplicated back into
/// a third screen with different metrics. Its green says "no un-migrated
/// literal", which is a true statement about literals and says nothing
/// about the view.
///
/// So the pin was LOWERED by one line (explicitly, in the script, with the
/// reason) and the obligation moved here. This file asserts the two facts
/// the script gave up:
///
///   1. the footer text is the joined token, not a bare glyph;
///   2. there is exactly ONE construction site, and both screens call it.
///
/// Fact 2 is structural on purpose. A behavioural assertion cannot see how
/// many times a `Text` is built — SwiftUI renders identically whether the
/// string comes from one shared view or three copies, which is precisely
/// the defect that produced this commit.
final class WordmarkTests: XCTestCase {

    // MARK: - substrate

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZeusTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        return try String(contentsOf: root.appendingPathComponent("Sources/ZeusApp/\(name)"),
                          encoding: .utf8)
    }

    /// Whole-line comments stripped. USE-vs-MENTION, fifth arrival on this
    /// app: the doc comment above `Wordmark.text` explains the bare-glyph
    /// defect by NAMING it, and a raw-text census would find the forbidden
    /// token inside the sentence forbidding it.
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - 1. the text

    /// POSITIVE on the token, NEGATIVE on the bare glyph outside it.
    ///
    /// The negative alone is satisfied by the empty string, so the positive
    /// is what makes it mean anything; the `NotEqual` is the vacuity arm —
    /// a `joined` that dropped both components would pass a "contains no
    /// bare dot" assertion by having no content at all.
    func testTheWordmarkIsBuiltFromTheTokenNotABareGlyph() {
        XCTAssertEqual(Wordmark.text, "ZEUS\u{00A0}\u{00B7}\u{00A0}NOVAXAI")
        XCTAssertTrue(Wordmark.text.contains(Theme.separator))
        XCTAssertFalse(Wordmark.text.replacingOccurrences(of: Theme.separator, with: "|")
                                    .contains("\u{00B7}"),
                       "bare `\u{00B7}` survives outside the token: \(Wordmark.text)")
        XCTAssertNotEqual(Wordmark.text, "", "an empty join passes every negative above")
        XCTAssertTrue(Wordmark.text.contains("NOVAXAI"))
    }

    // MARK: - 2. one construction site, two callers

    /// The census the script gave up when the literal disappeared.
    ///
    /// POS CONTROL IN THE SAME INVOCATION: a reader that opens the wrong
    /// path and a needle that matches nothing produce the same zero. Each
    /// leg asserts a token that is LIVE CODE in the slice it just read, so
    /// a strip that ate the body fails loudly instead of passing vacuously.
    func testExactlyOneSiteConstructsTheFooterAndBothScreensCallIt() throws {
        let wordmark = codeOnly(try source("Wordmark.swift"))
        let nodes    = codeOnly(try source("NodesView.swift"))
        let settings = codeOnly(try source("SettingsView.swift"))

        // POS controls: surviving code tokens, proving each read is alive.
        XCTAssertTrue(wordmark.contains("struct Wordmark"), "VOID: Wordmark.swift read empty")
        XCTAssertTrue(nodes.contains("struct NodesView"),   "VOID: NodesView.swift read empty")
        XCTAssertTrue(settings.contains("var body"),        "VOID: SettingsView.swift read empty")

        // THE ONE SITE. `Theme.joined` for this text is built exactly once
        // in the whole of Sources — counted here rather than pinned, because
        // the question is cardinality and a set pin cannot see a swap.
        XCTAssertEqual(wordmark.components(separatedBy: "Theme.joined([\"ZEUS\"").count - 1, 1,
                       "the footer text must be built exactly once")

        // Neither screen may build it again: the duplication this commit
        // repaired is the thing being forbidden, so it is asserted against
        // the two files that HAD the copies.
        for (name, src) in [("NodesView", nodes), ("SettingsView", settings)] {
            XCTAssertFalse(src.contains("NOVAXAI"),
                           "\(name) constructs the footer text again — it must call Wordmark()")
            XCTAssertTrue(src.contains("Wordmark()"),
                          "\(name) no longer renders the footer at all")
        }
    }

    /// The metrics travelled with the text.
    ///
    /// Not a rendering assertion — it is a source census, because SwiftUI
    /// gives no readable handle on an applied `.tracking`. Its value is
    /// that the four values now exist at ONE site; if a future screen wants
    /// a different footer it has to say so here, in the open.
    func testTheFooterMetricsLiveAtTheSameSingleSite() throws {
        let wordmark = codeOnly(try source("Wordmark.swift"))
        XCTAssertTrue(wordmark.contains("struct Wordmark"), "VOID: read empty")
        for metric in ["Theme.mono(8.5)", ".tracking(1.19)", "Theme.w(0.2)",
                       ".padding(.top, 18)", ".padding(.bottom, 8)"] {
            XCTAssertTrue(wordmark.contains(metric), "footer metric \(metric) left the one site")
        }
    }

    /// The pin was lowered, and the lowering is only honest if the script
    /// still reads the tree. Asserts the retired line is GONE from the pin
    /// AND that the pin is still populated — a script emptied of its set
    /// would satisfy the first half and guard nothing.
    func testTheSeparatorPinRetiredTheFooterWithoutGoingEmpty() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/check_separator_debt.sh"),
                                encoding: .utf8)
        let pinned = script.split(separator: "\n").filter { $0.hasPrefix("Sources/ZeusApp/") }
        XCTAssertGreaterThan(pinned.count, 20, "the pinned set emptied: the guard now guards nothing")
        XCTAssertFalse(pinned.contains { $0.contains("NOVAXAI") },
                       "the footer is still pinned as debt, but it was migrated")
    }
}
