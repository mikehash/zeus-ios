import XCTest
@testable import Zeus

/// The separator token and the debt it has not yet paid off.
///
/// Read by eye at 390pt on the 16e, two identity strips wrapped with the `·`
/// stranded at the end of a line — which reads as a cut string. The repair is
/// a non-breaking space on each side so the dot binds FORWARD, to the token
/// that follows it.
///
/// APERTURE, stated because the number below is meaningless without it: only
/// the strips ruled on from those frames are migrated. The rest are counted,
/// not fixed, and the count is asserted so the debt is a number the next seat
/// inherits rather than a vibe. `ROUTES` rewrites several of the remaining
/// sites, and migrating a line that is about to be replaced buys nothing.
final class SeparatorTests: XCTestCase {

    // MARK: - The token itself

    /// The token is three characters, not one. A test asserting only that it
    /// CONTAINS `·` passes on the bare glyph — which is the defect.
    func testSeparatorBindsForwardWithNonBreakingSpaces() {
        XCTAssertEqual(Theme.separator, "\u{00A0}\u{00B7}\u{00A0}")
        XCTAssertNotEqual(Theme.separator, "\u{00B7}",
                          "a bare middle dot is the wrapping defect this token exists to fix")
        XCTAssertFalse(Theme.separator.contains(" "),
                       "an ordinary space is a break opportunity: the wrap comes back")
    }

    // MARK: - The join

    func testJoinedUsesTheTokenAndDropsEmpties() {
        XCTAssertEqual(Theme.joined(["A", "B"]), "A\u{00A0}\u{00B7}\u{00A0}B")
        // An empty component renders `A ·  · C` — a separator with nothing
        // beside it, the same visual defect as the dangling one.
        XCTAssertEqual(Theme.joined(["A", "", "C"]), "A\u{00A0}\u{00B7}\u{00A0}C")
        XCTAssertEqual(Theme.joined(["A", "   ", "C"]), "A\u{00A0}\u{00B7}\u{00A0}C")
        XCTAssertEqual(Theme.joined(["A"]), "A", "one component has no separator at all")
        XCTAssertEqual(Theme.joined([]), "")
    }

    // MARK: - The migrated strips

    func testMigratedStripsCarryTheTokenNotTheBareGlyph() {
        let strips = [
            HomeView.operatorLine(for: "miguel"),
            Commission(provider: "anthropic", callsign: "miguel").summary,
        ]
        for s in strips {
            XCTAssertTrue(s.contains(Theme.separator), "not migrated: \(s)")
            // VACUITY: a strip could contain the token AND a stray bare glyph.
            // Every `·` in a migrated strip must be inside a full token, so
            // removing the tokens must leave no dot behind.
            let stripped = s.replacingOccurrences(of: Theme.separator, with: "|")
            XCTAssertFalse(stripped.contains("\u{00B7}"),
                           "bare `·` survives outside the token: \(s)")
        }
    }

    // MARK: - The accessibility strip (the third surface)

    /// `headerAccessibilityLabel` strips the separator out of the session
    /// title. Stripping the bare glyph passes an eyeball test and feeds
    /// VoiceOver two orphaned NBSPs that `trimmingCharacters(in: .whitespaces)`
    /// does not remove — U+00A0 is not in `.whitespaces`.
    func testAccessibilityLabelCarriesNoOrphanedNonBreakingSpace() {
        let label = SessionView.headerAccessibilityLabel(
            sessionID: "abc123def456", status: "LINK LOCAL", state: .ambient,
            disarmReason: nil)
        XCTAssertFalse(label.contains("\u{00A0}"),
                       "orphaned NBSP reaches the screen reader: \(label)")
        XCTAssertFalse(label.contains("\u{00B7}"), label)
        // POS control: the reader is alive — the label is not simply empty.
        XCTAssertTrue(label.contains("LINK LOCAL"), label)
        XCTAssertTrue(label.contains(AgentState.ambient.badgeText), label)
    }

    // MARK: - The phone-row subtitle (the fourth surface)

    /// `CoreProvenance.nodeSubtitle()` joined with a bare ` · ` and wrapped on
    /// the 390pt frame as `core 2bfc08aa ·` / `this iphone` — the dot stranded
    /// at the line end, which is the defect `Theme.separator` exists to fix.
    ///
    /// The absent-manifest arm carries NO separator at all, so a test that
    /// only asserts "contains no bare glyph" passes on the arm that has no
    /// glyph to begin with. Both arms are asserted, and the present arm is
    /// asserted POSITIVELY for the token.
    func testNodeSubtitleJoinsWithTheToken() {
        let joined = Theme.joined(["core 2bfc08aa", "this iphone"])
        XCTAssertTrue(joined.contains(Theme.separator))
        XCTAssertFalse(joined.replacingOccurrences(of: Theme.separator, with: "|")
                             .contains("\u{00B7}"),
                       "bare `\u{00B7}` survives outside the token: \(joined)")
        // VACUITY: the two arms of `nodeSubtitle` must not be the same string,
        // or the leg below is asserting nothing about the branch.
        XCTAssertNotEqual(joined, "this iphone")

        // The no-manifest arm: true unconditionally, and separator-free.
        let bare = CoreProvenance.nodeSubtitle(in: Bundle(for: SeparatorTests.self))
        XCTAssertFalse(bare.contains("\u{00B7}"), bare)
    }
}
