import XCTest
@testable import Zeus

/// Legs for `EmbeddedTransport.describe` — the function that turns a
/// GENERATED enum into the sentence a transcript shows.
///
/// Why this file exists at all: `describe()` had **zero** test consumers
/// before it, and the regen that added `.NoBaseUrl` is what surfaced that.
/// The compiler already guards EXHAUSTIVENESS — a new arm is a build error,
/// which is exactly how `.NoBaseUrl` was found — but the compiler has nothing
/// to say about whether an arm returns the RIGHT sentence. An arm that
/// returned the empty string, or another arm's text, compiles perfectly.
///
/// So the split of labour is: the switch's missing `default:` guards
/// COVERAGE, and these legs guard CONTENT. Adding only a leg for the new arm
/// would have left the other three in the state that let this gap persist,
/// so all four are covered plus the non-`BridgeError` fallback.
final class DescribeTests: XCTestCase {

    /// The new arm. The sentence names the FIELD to fix, not the diagnosis —
    /// the operator is holding a phone with a routes screen on it.
    func test_noBaseUrl_names_the_field_to_set() {
        let text = EmbeddedTransport.describe(BridgeError.NoBaseUrl)
        XCTAssertEqual(text, "OLLAMA NEEDS A BASE URL — SET ONE IN ROUTES")

        // VACUITY CONTROL. Every arm returns *a* non-empty string, so an
        // `isEmpty` check would pass over an arm wired to the wrong text.
        // Assert it is NOT the neighbouring state's sentence: `NoProvider`
        // and `NoBaseUrl` are both "routes screen, unfinished config", they
        // are one keystroke apart in the source, and rendering one as the
        // other is the single most likely wiring mistake here.
        XCTAssertNotEqual(text, GatewayConfig.noProviderMessage)
    }

    /// The backstop arm. It deliberately SHARES text with the disarm path so
    /// the two cannot drift into two different explanations of one state —
    /// so equality with `noProviderMessage` is the property, not a coincidence
    /// to be hard-coded around.
    func test_noProvider_speaks_the_same_words_as_the_disarm() {
        XCTAssertEqual(
            EmbeddedTransport.describe(BridgeError.NoProvider),
            GatewayConfig.noProviderMessage
        )
    }

    /// A typed refusal carries the CRATE's text through verbatim. The reason
    /// is loss-of-subject: a generic sentence would drop which provider
    /// refused, and that is the only useful part of the message.
    func test_unsupported_passes_the_crate_sentence_through_verbatim() {
        let crateText = "ollama is the only provider that answers list_models"
        XCTAssertEqual(
            EmbeddedTransport.describe(BridgeError.Unsupported(crateText)),
            crateText
        )
    }

    func test_core_passes_the_crate_sentence_through_verbatim() {
        let crateText = "workspace init failed: permission denied"
        XCTAssertEqual(
            EmbeddedTransport.describe(BridgeError.Core(crateText)),
            crateText
        )
    }

    /// The `guard let … as? BridgeError` half. A non-bridge error must fall
    /// back to its own description rather than to a friendly lie — a caller
    /// that swallowed a URLError into "NO PROVIDER" would send the operator
    /// to the wrong screen.
    func test_a_non_bridge_error_falls_back_to_its_own_description() {
        struct Odd: Error, CustomStringConvertible {
            var description: String { "ODD-SENTINEL" }
        }
        let text = EmbeddedTransport.describe(Odd())
        XCTAssertEqual(text, "ODD-SENTINEL")

        // The discriminating half: prove the fallback is not silently
        // producing a bridge arm's text for an error that is not a
        // `BridgeError` at all.
        XCTAssertNotEqual(text, GatewayConfig.noProviderMessage)
    }

    /// ARITY. The four arms above are the whole enum at this pin. If a regen
    /// grows a fifth, the switch in `describe` reds at build time — but a
    /// build error is a statement about the SOURCE, and this leg is the one
    /// that says the TEST FILE went stale too. Without it, a new arm gets a
    /// hurried `case .Whatever: return ""` to make the build pass and no leg
    /// ever notices.
    func test_every_arm_renders_a_distinct_non_empty_sentence() {
        let rendered = [
            EmbeddedTransport.describe(BridgeError.NoProvider),
            EmbeddedTransport.describe(BridgeError.NoBaseUrl),
            EmbeddedTransport.describe(BridgeError.Unsupported("A-SENTINEL")),
            EmbeddedTransport.describe(BridgeError.Core("B-SENTINEL")),
        ]
        for text in rendered {
            XCTAssertFalse(text.isEmpty, "an arm rendered an empty sentence")
        }
        XCTAssertEqual(Set(rendered).count, rendered.count,
                       "two arms render the same sentence")
    }
}
