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

    /// ARITY. If a regen grows an arm, the switch in `describe` reds at build
    /// time — but a build error is a statement about the SOURCE, and this leg
    /// is the one that says the TEST FILE went stale too. Without it, a new arm
    /// gets a hurried `case .Whatever: return ""` to make the build pass and no
    /// leg ever notices.
    ///
    /// 🔴 It went stale exactly as predicted, and the prediction is why it was
    /// caught: this list read FOUR arms while the enum carried six —
    /// `.EmptyAttachment` had landed with the attach arc and never reached
    /// here. A leg that enumerates by hand cannot detect its own omission, so
    /// the count is now asserted against the enum's rendered set below, and
    /// the number is the thing a regen must come back and change.
    func test_every_arm_renders_a_distinct_non_empty_sentence() {
        let rendered = [
            EmbeddedTransport.describe(BridgeError.NoProvider),
            EmbeddedTransport.describe(BridgeError.NoBaseUrl),
            EmbeddedTransport.describe(BridgeError.Unsupported("A-SENTINEL")),
            EmbeddedTransport.describe(BridgeError.Core("B-SENTINEL")),
            EmbeddedTransport.describe(BridgeError.EmptyAttachment),
            EmbeddedTransport.describe(BridgeError.NotAnImage("application/pdf")),
        ]
        for text in rendered {
            XCTAssertFalse(text.isEmpty, "an arm rendered an empty sentence")
        }
        XCTAssertEqual(Set(rendered).count, rendered.count,
                       "two arms render the same sentence")
        XCTAssertEqual(rendered.count, 6,
                       "BridgeError grew or shrank an arm — update this list AND the count")
    }

    /// The vision refusal NAMES the file it refused and points somewhere real.
    ///
    /// Load-bearing because of where the alternative failure lives: both
    /// dialect formatters in `zeus-llm::multimodal` return nil for a non-image,
    /// which drops the attachment one layer BELOW the bridge and lets the turn
    /// read as though the model saw it. `.NotAnImage` exists to make that
    /// audible, so a sentence that omitted the mime would restore half the
    /// defect — the operator would know something was refused but not what.
    func test_the_vision_refusal_names_the_mime_and_the_working_channel() {
        let text = EmbeddedTransport.describe(BridgeError.NotAnImage("application/pdf"))

        XCTAssertTrue(text.contains("APPLICATION/PDF"),
                      "the refusal does not name what was refused: \(text)")
        XCTAssertTrue(text.contains("ISN'T AN IMAGE"),
                      "the refusal does not say why: \(text)")
        XCTAssertTrue(text.contains("FILE"),
                      "the refusal names no channel that does work: \(text)")

        // It must not read as a breakage. The honest answer is "wrong channel",
        // not "the app failed" — same discipline as the empty-pick sentence.
        //
        // MEASURED ON THE COMPOSED SENTENCE, not on `describe`'s fragment.
        // This assertion was green for an entire arc while the operator read
        // "LOCAL CORE ERROR — APPLICATION/PDF ISN'T AN IMAGE…", because the
        // fragment is honest and the envelope `.embedded` wraps it in is not.
        // Right substring, wrong scope. What reaches the transcript is
        // `TransportError.errorDescription`, so that is what is asserted.
        let composed = EmbeddedTransport
            .transportError(for: BridgeError.NotAnImage("application/pdf"))
            .errorDescription ?? ""
        XCTAssertTrue(composed.contains("APPLICATION/PDF"),
                      "the composed sentence lost the mime: \(composed)")
        for alarm in ["ERROR", "FAILED", "UNAVAILABLE"] {
            XCTAssertFalse(composed.contains(alarm),
                           "a channel mismatch is rendered as a fault: \(composed)")
        }

        // POS control on the strip above: the same walk over a genuine FAULT
        // must FIND an alarm word. Without this, the loop passes identically
        // against an empty `composed`, and the leg would be vacuous in exactly
        // the direction that looks like success.
        let fault = EmbeddedTransport
            .transportError(for: BridgeError.Core("workspace is read-only"))
            .errorDescription ?? ""
        XCTAssertTrue(fault.contains("ERROR"),
                      "a real core fault stopped shouting — the strip is vacuous: \(fault)")

        // Vacuity control: a DIFFERENT mime must render differently, or the
        // assertions above are consistent with a fixed string.
        let other = EmbeddedTransport.describe(BridgeError.NotAnImage("text/plain"))
        XCTAssertNotEqual(text, other,
                          "the arm ignores its payload — the mime is decoration")
    }
}
