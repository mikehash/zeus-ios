import XCTest
@testable import Zeus

// Guards contract points 1–3 of Sources/ZeusApp/RealtimeStream.swift.
// The sink is driven directly, the way the Rust runtime drives it, so no
// socket and no key are involved.

private func drain(_ events: AsyncStream<RealtimeEvent>) async -> [RealtimeEvent] {
    var out: [RealtimeEvent] = []
    for await e in events { out.append(e) }
    return out
}

final class RealtimeStreamTests: XCTestCase {

    func test_frames_then_close_arrive_in_order_and_finish_the_stream() async {
        let (sink, events, _) = RealtimeEvents.make()
        sink.onText(frame: "hello")
        sink.onBinary(frame: Data([1, 2, 3]))
        sink.onClosed(code: 1000, reason: "bye")
        let got = await drain(events)   // returns only because the stream finished
        XCTAssertEqual(got, [.text("hello"), .binary(Data([1, 2, 3])),
                             .closed(code: 1000, reason: "bye")])
    }

    // NOTE: sequentially, AsyncStream's own finish() already drops later
    // yields, so this leg stays green with the sink's terminal guard deleted
    // (measured). The guard is load-bearing only under concurrent delivery —
    // the race test below is the one that reddens without it.
    func test_nothing_after_the_terminal_reaches_the_consumer() async {
        let (sink, events, _) = RealtimeEvents.make()
        sink.onError(message: "reset")
        sink.onText(frame: "late")
        sink.onClosed(code: 1000, reason: "also late")
        let got = await drain(events)
        XCTAssertEqual(got, [.failed("reset")])
        XCTAssertEqual(got.filter(\.isTerminal).count, 1)
    }

    func test_a_closed_without_a_close_frame_keeps_its_nil_code() async {
        let (sink, events, _) = RealtimeEvents.make()
        sink.onClosed(code: nil, reason: "")
        let got = await drain(events)
        XCTAssertEqual(got, [.closed(code: nil, reason: "")])
        XCTAssertNotEqual(got, [.closed(code: 1000, reason: "")])  // vacuity: nil ≠ 1000
    }

    func test_overflow_drops_old_frames_never_the_terminal() async {
        let (sink, events, _) = RealtimeEvents.make(bufferLimit: 3)
        for i in 0..<10 { sink.onText(frame: "f\(i)") }   // nobody consuming yet
        sink.onClosed(code: 1000, reason: "end")
        let got = await drain(events)
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got.last, .closed(code: 1000, reason: "end"))
        XCTAssertEqual(Array(got.dropLast()), [.text("f8"), .text("f9")])
    }

    // Probabilistic, so it repeats: one round passed against the
    // unlock-before-yield version that a later full run caught.
    func test_terminal_from_another_thread_races_frames_and_still_ends_once() async {
        for round in 0..<50 {
            let (sink, events, _) = RealtimeEvents.make(bufferLimit: 10_000)
            DispatchQueue.concurrentPerform(iterations: 200) { i in
                if i == 100 { sink.onError(message: "boom") } else { sink.onText(frame: "\(i)") }
            }
            sink.onClosed(code: 1000, reason: "after")
            let got = await drain(events)
            XCTAssertEqual(got.filter(\.isTerminal), [.failed("boom")], "round \(round)")
            XCTAssertEqual(got.last, .failed("boom"), "round \(round)")
            if got.last != .failed("boom") { return }
        }
    }

    func test_a_failed_connect_throws_unchanged() {
        var sinkSeen: RealtimeSink?
        let refuse: RealtimeConnector = { _, sink in
            sinkSeen = sink
            throw RealtimeError.Connect("fake core: no realtime")
        }
        XCTAssertThrowsError(try openRealtime(RealtimeConnect(url: "ws://127.0.0.1:1", headers: []),
                                              via: refuse)) {
            guard case RealtimeError.Connect(let m) = $0 else { return XCTFail("wrong error \($0)") }
            XCTAssertEqual(m, "fake core: no realtime")
        }
        // The stream was finished on the throw: a terminal yielded afterwards
        // through the sink the connector saw must not surface anywhere, and
        // a second finish must not trap.
        XCTAssertNotNil(sinkSeen)
        sinkSeen?.onClosed(code: 1000, reason: "after refusal")
    }
}
