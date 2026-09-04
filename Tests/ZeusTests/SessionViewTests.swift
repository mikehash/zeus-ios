import XCTest
@testable import Zeus

/// The header identifier was the literal `"SESSION-01"` for three commits
/// while the real gateway-named id sat one field away at `Session.swift:197`,
/// `private` and with no reader. Same class as `"last seen t-12min"`: a value
/// with the SHAPE of data that nothing recorded — and worse, because the true
/// value existed and was being ignored rather than merely absent.
///
/// The derivation is a `static func` for the reason HomeView's six are: a
/// SwiftUI body is not observable in-process, so a derivation left inline in
/// the view is guardable only by screenshot — which is exactly how the three
/// literal-status defects survived.
/// Local conformer. `ScriptedTransport` is `private` to the failure-test file
/// and stays that way — widening a test helper's access to reach it from a
/// second file couples two suites that share nothing but a protocol.
private struct SilentTransport: SessionTransport {
    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
final class SessionViewTests: XCTestCase {

    // MARK: - The absence arm

    /// Before any turn the gateway has named nothing. The honest render is an
    /// absence, not a placeholder number.
    func testNilSessionRendersEmDashNotANumber() {
        let title = SessionView.sessionTitle(for: nil)
        XCTAssertEqual(title, "SESSION · —")
        XCTAssertFalse(title.contains("01"), "a fabricated ordinal is the defect this replaced")
    }

    /// An empty string is the same absence as nil — a gateway that sends
    /// `"session_id": ""` must not produce `"SESSION · "`.
    func testEmptySessionIsTreatedAsAbsent() {
        XCTAssertEqual(SessionView.sessionTitle(for: ""), "SESSION · —")
    }

    // MARK: - The named arm

    func testNamedSessionRendersTruncatedUppercaseID() {
        let title = SessionView.sessionTitle(for: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        XCTAssertEqual(title, "SESSION · A1B2C3D4")
    }

    /// VACUITY FLOOR for the truncation: an id SHORTER than the bound must
    /// render whole. Without this leg a `prefix` bug that returned "" would
    /// pass every other assertion in the absence direction.
    func testShortSessionRendersWhole() {
        XCTAssertEqual(SessionView.sessionTitle(for: "abc"), "SESSION · ABC")
    }

    /// The two arms must not collapse. `assert_ne`-style: a derivation that
    /// returned the same string for both states would satisfy neither claim
    /// while looking correct in a screenshot of either.
    func testNamedAndAbsentArmsDiffer() {
        XCTAssertNotEqual(
            SessionView.sessionTitle(for: nil),
            SessionView.sessionTitle(for: "deadbeef")
        )
    }

    // MARK: - The engine mirror

    /// The label starts absent. The engine holds a `SessionIDBox` from
    /// construction, but the BOX being non-nil is not the same claim as the
    /// gateway having NAMED an id.
    func testEngineLabelStartsNil() {
        let engine = SessionEngine(transport: SilentTransport())
        XCTAssertNil(engine.sessionLabel)
    }

    // MARK: - The mirror is WIRED (the discriminating leg)

    /// 🔴 `SilentTransport` STRUCTURALLY CANNOT discriminate this.
    ///
    /// It finishes with no frames, so nothing ever writes the box;
    /// `syncSessionLabel()` then compares nil to nil and sets nothing. Delete
    /// the sync entirely and that path is byte-identical. **The vacuity is in
    /// the TRANSPORT, not in the assertion** — which is why widening the
    /// existing legs cannot reach it, and why this leg brings its own
    /// conformer that WRITES.
    ///
    /// It is also the only leg in the suite that exercises the designated
    /// `init(makeTransport:)`. Both convenience inits spell the closure
    /// `{ _ in transport }`, which DISCARDS the box — so the designated
    /// init's own parameter was unguarded by construction: 17 of 17
    /// `SessionEngine(` sites in Tests went through the convenience pair.
    ///
    /// Recorder is a `final class` captured by the closure rather than
    /// `static var` state on the conformer: `SessionTransport` refines
    /// `Sendable` (Session.swift:17), so a conformer holding mutable state
    /// needs `@unchecked Sendable` or a lock — and whether that is an error
    /// or a warning is decided by a language mode that NO tracked file in
    /// this repo pins. A captured recorder removes the dependency instead of
    /// conforming to it, and there is no reset prologue to forget.
    func testEngineMirrorsTheIDTheTransportWroteIntoItsBox() async {
        let recorder = BoxRecorder()
        // 🔴 `seed: []` is load-bearing, not tidiness. The designated init
        // defaults to a ONE-message seed, so `count == 2` is true the instant
        // `send` returns — before `run` has constructed anything. The floor
        // then reads 0 over a settle that returned at t=0. That is the
        // `:198` comment's warning arriving from a third direction.
        let engine = SessionEngine(makeTransport: { box in
            recorder.append(box)
            return BoxWritingTransport(box: box, id: "abc123de-ffff")
        }, seed: [])

        engine.send("first")
        await settle("turn 1 settles") {
            engine.messages.count == 2 && !engine.messages[1].streaming
                && engine.state == .ambient
        }

        // VACUITY FLOOR, and it is not decoration: an un-awaited assert reads
        // ZERO constructions because `send` is fire-and-forget, and a bare
        // sleep instead of a settle reads TWO constructions over a run whose
        // first turn never streamed. The floor is what makes the identity
        // assertion below readable at all.
        XCTAssertEqual(recorder.count, 1, "factory never called — leg is vacuous")
        XCTAssertEqual(engine.sessionLabel, "abc123de-ffff")
    }

    /// ONE box outlives MANY transports — the whole point of the hoist.
    ///
    /// Two turns, each constructing a fresh transport through the factory.
    /// If the engine handed out a new `SessionIDBox()` per turn, the identity
    /// assertion reddens while the floor stays green: that two-valued split
    /// is what makes this leg a measurement rather than a smoke test.
    ///
    /// 🔴 The turns are AWAITED individually, not back-to-back sends.
    /// `send` cancels the in-flight turn before spawning the next, and a
    /// cancelled Swift task STILL RUNS ITS BODY up to the first cancellation
    /// check — which sits inside the `for await`, AFTER the transport is
    /// constructed. Back-to-back sends therefore record two constructions
    /// over one completed turn, and the count cannot tell that apart from
    /// two real turns.
    ///
    /// Both carets are named because `state` is ONE shared field: turn 1's
    /// `defer` can set `.ambient` while turn 2 is mid-stream, so a predicate
    /// that only inspects `last` is a complete terminal condition for turn 2
    /// and says nothing about turn 1.
    func testOneBoxOutlivesEveryTransportAcrossTurns() async {
        let recorder = BoxRecorder()
        let engine = SessionEngine(makeTransport: { box in
            recorder.append(box)
            return BoxWritingTransport(box: box, id: "abc123de-ffff")
        }, seed: [])   // see the note in the preceding leg

        engine.send("first")
        await settle("turn 1 settles") {
            engine.messages.count == 2 && !engine.messages[1].streaming
                && engine.state == .ambient
        }
        engine.send("second")
        await settle("turn 2 settles, BOTH carets cleared") {
            engine.messages.count == 4
                && !engine.messages[1].streaming
                && !engine.messages[3].streaming
                && engine.state == .ambient
        }

        XCTAssertEqual(recorder.count, 2, "not two completed turns — leg is vacuous")
        XCTAssertTrue(recorder[0] === recorder[1],
                      "engine handed a DIFFERENT box per turn — identity does not survive")
    }

    // MARK: - Harness

    /// Bounded: a hang fails the leg instead of hanging the suite.
    private func settle(_ label: String,
                        file: StaticString = #filePath,
                        line: UInt = #line,
                        _ predicate: () -> Bool) async {
        for _ in 0..<5000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("never settled: \(label)", file: file, line: line)
    }

}

/// Writes an id into whatever box the engine hands it, then finishes.
///
/// A `struct` because all five `SessionTransport` conformers tree-wide are
/// structs and the protocol refines `Sendable`; the box it holds already
/// carries `@unchecked Sendable` (HTTPTransport.swift:50).
private struct BoxWritingTransport: SessionTransport {
    let box: SessionIDBox
    let id: String

    func stream(prompt: String) -> AsyncThrowingStream<SessionFrame, Error> {
        box.set(id)                      // API at HTTPTransport.swift:164
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("ok"))
            continuation.finish()
        }
    }
}

/// Records every box the factory is handed. `final class` so the closure
/// captures a REFERENCE — a struct recorder would record into a copy and
/// report zero. Instantiated per test: no global state, no reset prologue.
private final class BoxRecorder: @unchecked Sendable {
    private var seen: [SessionIDBox] = []
    func append(_ box: SessionIDBox) { seen.append(box) }
    var count: Int { seen.count }
    subscript(i: Int) -> SessionIDBox { seen[i] }
}

