import XCTest
@testable import Zeus

/// Legs for the route catalogue behind the C12 sheet.
///
/// Every leg here was written against its own VACUOUS form first — the form
/// that would pass on a stub — and only kept if the vacuous form fails.
final class RouteTests: XCTestCase {

    // MARK: - The subtitle is derived, not transcribed

    /// THE DEFECT THIS EXISTS FOR: the prototype renders `11 PROVIDERS
    /// ENROLLED` (`ZeusApp.jsx:769`) immediately above a `.map` over an array
    /// of eight. A verbatim transcription ships a count that the list below it
    /// refutes.
    ///
    /// The vacuous form is `XCTAssertFalse(subtitle.isEmpty)` — which passes
    /// on the hardcoded "11 PROVIDERS ENROLLED" string, i.e. on exactly the
    /// defect. The discriminating form ties the rendered number to the
    /// array's own length, so the two cannot drift.
    func testSubtitleCountIsDerivedFromTheCatalogueNotLiteral() {
        XCTAssertEqual(
            RouteCatalog.subtitle,
            "\(RouteCatalog.all.count) PROVIDERS ENROLLED",
            "the header count must come from the array it labels"
        )
        // And it must not be the prototype's contradicted literal. This is the
        // arm that fails if someone "restores parity" by pasting 11 back.
        XCTAssertFalse(
            RouteCatalog.subtitle.hasPrefix("11 "),
            "the prototype's 11 contradicts its own 8-element array"
        )
    }

    /// The count itself, pinned so a silently-dropped route is visible.
    func testCatalogueHoldsTheEightRoutesTheProtoypeEnumerates() {
        XCTAssertEqual(RouteCatalog.all.count, 8)
        XCTAssertEqual(
            RouteCatalog.all.map(\.id),
            ["auto", "anthropic", "openai", "google", "xai", "groq",
             "deepseek", "ollama"],
            "ids and order are transcribed from ZeusApp.jsx:322-331"
        )
    }

    /// Selection is keyed on `id`, so a duplicate would make two rows
    /// highlight at once and one of them unselectable.
    func testRouteIDsAreUnique() {
        let ids = RouteCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - No fabricated measurements

    /// THE LITERAL-STATUS FAMILY, ONE MORE TIME. The prototype's `meta`
    /// carries `P50 180MS`, `P50 90MS`, `P50 320MS` — hardcoded numbers in a
    /// mock, in a slot the eye reads as a measurement. This app has no latency
    /// instrument, so any such string here would be fabricated.
    ///
    /// The vacuous form — "every route has a non-empty reach" — passes on a
    /// catalogue full of `P50` strings. This one names the defect.
    func testNoRouteAdvertisesALatencyNothingMeasured() {
        for route in RouteCatalog.all {
            let text = route.reach.rawValue
            XCTAssertFalse(text.contains("P50"),
                           "\(route.id) advertises a p50 with no instrument behind it")
            XCTAssertFalse(text.contains("MS"),
                           "\(route.id) advertises a latency with no instrument behind it")
        }
        // Vacuity control: the assertion above is trivially satisfied by an
        // empty catalogue or empty strings. Prove there was something to check.
        XCTAssertGreaterThan(RouteCatalog.all.count, 0)
        XCTAssertTrue(RouteCatalog.all.allSatisfy { !$0.reach.rawValue.isEmpty })
    }

    /// `reach` must actually discriminate — a three-case enum where every
    /// route picks the same case carries no information, and would pass every
    /// leg above.
    func testReachDistinguishesTopologyItDoesNotCollapse() {
        let reaches = Set(RouteCatalog.all.map(\.reach))
        XCTAssertGreaterThan(reaches.count, 1, "reach collapsed to a constant")
        XCTAssertEqual(RouteCatalog.all.first { $0.id == "ollama" }?.reach, .lanOnly)
        XCTAssertEqual(RouteCatalog.all.first { $0.id == "auto" }?.reach, .routed)
        XCTAssertEqual(RouteCatalog.all.first { $0.id == "anthropic" }?.reach, .direct)
        // ...and the three named above are genuinely three values.
        XCTAssertNotEqual(Route.Reach.lanOnly, .direct)
        XCTAssertNotEqual(Route.Reach.routed, .direct)
    }

    // MARK: - The default is a member of the catalogue

    /// The row previously read `"LOCAL · MLX"` — a string naming a route that
    /// is not in the catalogue. With a sheet in front of it, a default outside
    /// the list renders as "nothing is selected" the moment it opens: no row
    /// highlights, and the operator cannot tell whether that is a bug or a
    /// state. The vacuous form ("fallback is non-nil") passes on any Route at
    /// all, including a synthesised one.
    func testFallbackIsAMemberOfTheCatalogueSoARowHighlights() {
        XCTAssertTrue(
            RouteCatalog.all.contains(RouteCatalog.fallback),
            "the default must be selectable in the sheet it opens"
        )
        XCTAssertEqual(RouteCatalog.fallback.id, "ollama")
        XCTAssertFalse(
            RouteCatalog.all.map(\.name).contains("LOCAL · MLX"),
            "the retired literal must not have been re-added as a ninth route"
        )
    }
}
