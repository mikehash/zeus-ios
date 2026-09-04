import XCTest
@testable import Zeus

/// Guards on `zeus://` routing.
///
/// The load-bearing legs are the REFUSALS. A parser that accepts everything
/// and returns `.tab(.zeus)` would pass every "this link works" assertion
/// while navigating the user somewhere no URL asked for.
final class DeepLinkTests: XCTestCase {

    private func parse(_ s: String) -> DeepLink? {
        guard let url = URL(string: s) else {
            XCTFail("fixture is not a URL: \(s)")
            return nil
        }
        return DeepLink.parse(url)
    }

    // MARK: - Accept

    /// VACUITY FLOOR. Without this, every refusal assertion below would pass
    /// against a parser that returns `nil` unconditionally — `nil == nil` for
    /// a function that does nothing at all.
    func testTabLinkResolves() {
        XCTAssertEqual(parse("zeus://nodes"), .tab(.nodes))
        XCTAssertEqual(parse("zeus://session"), .tab(.session))
        XCTAssertEqual(parse("zeus://zeus"), .tab(.zeus))
    }

    /// RFC 3986 §3.1/§3.2.2: scheme and host are case-insensitive, and iOS
    /// hands over whatever the sender typed.
    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(parse("ZEUS://NODES"), .tab(.nodes))
        XCTAssertEqual(parse("Zeus://Session"), .tab(.session))
    }

    func testSessionPromptIsCarried() {
        XCTAssertEqual(parse("zeus://session?prompt=status%20report"),
                       .session(prompt: "status report"))
    }

    /// `+` is form-encoding, not RFC 3986 — `URLComponents` leaves it alone.
    /// A human typing a link uses it constantly.
    func testPlusDecodesAsSpace() {
        XCTAssertEqual(parse("zeus://session?prompt=hello+zeus"),
                       .session(prompt: "hello zeus"))
    }

    // MARK: - Refuse

    /// THE NO-FALLBACK RULE. An unknown host must not land on any tab.
    func testUnknownHostRefuses() {
        XCTAssertNil(parse("zeus://settings"))
        XCTAssertNil(parse("zeus://node/kitchen"))
    }

    func testForeignSchemeRefuses() {
        XCTAssertNil(parse("https://session"))
        XCTAssertNil(parse("zeusx://session"))
    }

    func testHostlessRefuses() {
        XCTAssertNil(parse("zeus://"))
    }

    // MARK: - Three states of `prompt`

    /// Absent and empty are the SAME destination — a plain session tab, with
    /// an untouched composer. Returning `.session(prompt: "")` would mark the
    /// field dirty with nothing in it.
    func testEmptyPromptFoldsToPlainTab() {
        XCTAssertEqual(parse("zeus://session?prompt="), .tab(.session))
        XCTAssertEqual(parse("zeus://session?prompt=%20%20"), .tab(.session))
        XCTAssertEqual(parse("zeus://session"), .tab(.session))
    }

    /// A prompt on a tab with no composer is ignored, NOT redirected. The URL
    /// asked for NODES; honouring the prompt would require going elsewhere.
    func testPromptOnNonSessionTabIsIgnored() {
        XCTAssertEqual(parse("zeus://nodes?prompt=hello"), .tab(.nodes))
        XCTAssertEqual(parse("zeus://zeus?prompt=hello"), .tab(.zeus))
    }

    /// Duplicate keys have no defined meaning; first-wins is at least a rule.
    func testDuplicatePromptTakesTheFirst() {
        XCTAssertEqual(parse("zeus://session?prompt=a&prompt=b"),
                       .session(prompt: "a"))
    }

    // MARK: - Exhaustiveness

    /// Every `Tab` case must have a working link. `CaseIterable` means adding
    /// a fourth tab fails HERE rather than shipping a dead link — the leg is
    /// structural, not a list someone has to remember to extend.
    func testEveryTabIsReachable() {
        XCTAssertEqual(Tab.allCases.count, 3, "floor: the enum still has 3 tabs")
        for t in Tab.allCases {
            XCTAssertEqual(parse("zeus://\(t.rawValue)"), .tab(t),
                           "tab \(t.rawValue) has no working deep link")
        }
    }
}
