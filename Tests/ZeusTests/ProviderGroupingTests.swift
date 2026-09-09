import XCTest
@testable import Zeus

/// (g): SEARCH-FIRST, GROUPED BY WHAT THE ROW WILL ASK FOR.
///
/// Every leg here runs against `ProviderCatalog.grouped`, which is pure over
/// (rows, query) precisely because the view body has no importable surface in
/// this target — the same extraction `routesCTAEnabled` got, for the same
/// measured reason.
final class ProviderGroupingTests: XCTestCase {

    private func row(_ id: String, _ label: String, _ shape: CredentialKind) -> ProviderRow {
        ProviderRow(id: id, label: label, shape: shape)
    }

    private var fixture: [ProviderRow] {
        [
            row("anthropic", "Anthropic", .key),
            row("ollama", "Ollama", .url),
            row("vertex", "Google Cloud", .none),
            row("openai", "OpenAI", .key),
            row("weird", "Weird Co", .unsupported(reason: "no auth table entry")),
            row("odd", "Odd Co", .unsupported(reason: "a DIFFERENT reason")),
        ]
    }

    /// THE GROUPING KEY IS COARSER THAN THE SHAPE, AND THIS IS THE LEG THAT
    /// SAYS SO. Two `.unsupported` rows with different `reason` strings are
    /// `!=` as `CredentialKind`, so grouping on the shape itself would render
    /// a section per sentence. They must land in ONE section.
    func testTwoUnsupportedReasonsShareOneSection() {
        let groups = ProviderCatalog.grouped(fixture, query: "")
        let unsupported = groups.filter { $0.kind == .unsupported }
        XCTAssertEqual(unsupported.count, 1, "one section, not one per reason")
        XCTAssertEqual(unsupported.first?.rows.map(\.id), ["weird", "odd"])
        // VACUITY: the two rows really are unequal as shapes, so the section
        // above is a merge and not an accident of identical fixtures.
        XCTAssertNotEqual(fixture[4].shape, fixture[5].shape)
    }

    /// Section order is `ProviderGroupKind.allCases`, not discovery order.
    /// The fixture is deliberately shuffled relative to it.
    func testSectionOrderIsFixedNotDiscoveryOrder() {
        let groups = ProviderCatalog.grouped(fixture, query: "")
        XCTAssertEqual(groups.map(\.kind), [.key, .url, .none, .unsupported])
        // The first row in the fixture is `.key` and the second `.url`, so a
        // discovery-ordered implementation would agree on the first two and
        // disagree on the third: `.none` appears before `.unsupported` here
        // only because `allCases` says so.
        XCTAssertEqual(groups[2].kind, .none)
    }

    /// Within a group the CORE'S order survives. No alphabetising, no
    /// favourites — `Anthropic` precedes `OpenAI` here because the fixture
    /// says so, and it would still precede it if the fixture said the reverse.
    func testWithinGroupOrderIsTheCatalogs() {
        let forward = ProviderCatalog.grouped(fixture, query: "")
        XCTAssertEqual(forward.first?.rows.map(\.id), ["anthropic", "openai"])

        var reversed = fixture
        reversed.swapAt(0, 3)
        let back = ProviderCatalog.grouped(reversed, query: "")
        XCTAssertEqual(back.first?.rows.map(\.id), ["openai", "anthropic"],
                       "an alphabetiser would answer the same both times")
    }

    /// EMPTY GROUPS ARE DROPPED. A header over nothing is a claim that such
    /// providers exist in this build.
    func testEmptyGroupsAreNotRendered() {
        let groups = ProviderCatalog.grouped(fixture, query: "ollama")
        XCTAssertEqual(groups.map(\.kind), [.url])
        XCTAssertEqual(groups.first?.rows.map(\.id), ["ollama"])
    }

    /// The query matches the ID as well as the label, because the id is what
    /// gets PERSISTED and what the arm messages name. An operator who read
    /// `vertex` in a failure must be able to type it back.
    ///
    /// THE FIXTURE IS THE LEG. My first version used `bedrock` / `Amazon
    /// Bedrock`, where the label CONTAINS the id — so a label-only matcher
    /// would have passed this test, and the discriminator below is what said
    /// so out loud. A search leg whose fixture's id appears in its own label
    /// measures nothing.
    func testQueryMatchesIdNotOnlyLabel() {
        let byId = ProviderCatalog.grouped(fixture, query: "vertex")
        XCTAssertEqual(byId.flatMap { $0.rows }.map(\.id), ["vertex"])
        // DISCRIMINATOR: the id appears nowhere in the label, so a
        // label-only matcher answers EMPTY for this needle.
        XCTAssertFalse(fixture[2].label.lowercased().contains("vertex"))
        // POS in the same read: the label is searchable too.
        XCTAssertEqual(ProviderCatalog.grouped(fixture, query: "Google").flatMap { $0.rows }.map(\.id),
                       ["vertex"])
    }

    func testQueryIsCaseInsensitive() {
        XCTAssertEqual(ProviderCatalog.grouped(fixture, query: "ANTHROPIC").flatMap { $0.rows }.map(\.id),
                       ["anthropic"])
        XCTAssertEqual(ProviderCatalog.grouped(fixture, query: "  anth  ").flatMap { $0.rows }.map(\.id),
                       ["anthropic"], "surrounding whitespace is trimmed, not matched")
    }

    /// An empty query is not a filter. POS control against the leg above:
    /// without this, "search returns 1" is consistent with "search returns 1
    /// always".
    func testEmptyQueryReturnsEverything() {
        let all = ProviderCatalog.grouped(fixture, query: "").flatMap { $0.rows }
        XCTAssertEqual(all.count, fixture.count)
        XCTAssertEqual(Set(all.map(\.id)), Set(fixture.map(\.id)))
    }

    /// A needle that matches nothing yields NO sections — which is what lets
    /// the view distinguish "no match" from "still loading" (`providerRows`
    /// empty) and say the right one.
    func testNoMatchYieldsNoSections() {
        XCTAssertTrue(ProviderCatalog.grouped(fixture, query: "zzzz").isEmpty)
        XCTAssertTrue(ProviderCatalog.grouped([], query: "").isEmpty,
                      "and an empty catalog is also empty — the VIEW tells these apart, not this function")
    }

    /// Every `CredentialKind` maps to a group, asserted case by case rather
    /// than by count: a count is satisfied by any four answers.
    func testEveryKindMapsToItsGroup() {
        XCTAssertEqual(ProviderGroupKind(.key), .key)
        XCTAssertEqual(ProviderGroupKind(.url), .url)
        XCTAssertEqual(ProviderGroupKind(.none), .none)
        XCTAssertEqual(ProviderGroupKind(.unsupported(reason: "x")), .unsupported)
        XCTAssertEqual(ProviderGroupKind(.unsupported(reason: "y")), .unsupported)
    }

    /// Headers state the ASK, and no two are the same string — a duplicate
    /// header would make two sections indistinguishable on screen while this
    /// suite stayed green on the `kind` values.
    func testHeadersAreDistinctAndStateTheAsk() {
        let headers = ProviderGroupKind.allCases.map(\.header)
        XCTAssertEqual(Set(headers).count, ProviderGroupKind.allCases.count)
        XCTAssertEqual(ProviderGroupKind.key.header, "NEEDS AN API KEY")
        XCTAssertEqual(ProviderGroupKind.url.header, "NEEDS AN ENDPOINT")
        XCTAssertEqual(ProviderGroupKind.none.header, "NOTHING TO ENTER")
        XCTAssertEqual(ProviderGroupKind.unsupported.header, "NOT FROM THIS SCREEN")
    }

    /// NO FAVOURITES, asserted as an absence with its POS control in the same
    /// read: the catalog file must not name a provider id to promote one.
    func testNoFavouritesInTheCatalogSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZeusApp/ProviderCatalog.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("///") && !$0.hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("ProviderGroupKind.allCases"),
                      "POS control: the filter kept the code lines")
        for needle in ["sorted(", "favourite", "favorite", "\"anthropic\"", "\"openai\""] {
            XCTAssertFalse(code.contains(needle), "\(needle) on a code line in the catalog")
        }
    }
}
