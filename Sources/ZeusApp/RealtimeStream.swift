import Foundation

// Voice ② — Swift side of the realtime session (rust/zeus-core-bridge/src/realtime.rs).
//
// The bridge delivers inbound frames through `RealtimeSink` callbacks on a
// Rust runtime thread. This file turns those callbacks into one
// `AsyncStream<RealtimeEvent>` so a consumer can `for await` the session.
//
// AUTH-INDEPENDENT ON PURPOSE. `RealtimeConnect` carries the URL and headers
// verbatim; whether the credential is a device-held key or a short-lived
// token is decided by whoever builds the `RealtimeConnect`, not here.
//
// Contract:
//  1. Exactly one terminal event (`.closed` or `.failed`) ends the stream.
//     The Rust side already guarantees one terminal callback; this side
//     additionally ignores anything that arrives after it.   [RealtimeStreamTests]
//  2. The terminal event is never the one dropped. The buffer keeps the
//     NEWEST `bufferLimit` events, and the terminal is always newest when it
//     is yielded.                                             [RealtimeStreamTests]
//  3. A failed connect leaves a finished stream, not a dangling one.
//                                                             [RealtimeStreamTests]
//  4. A consumer that stops iterating (cancel) closes the session, so an
//     abandoned stream cannot hold a socket open.  NOT YET GUARDED: proving it
//     needs a live `RealtimeSession`, i.e. the real core against a local
//     WebSocket server — next phase.

enum RealtimeEvent: Equatable, Sendable {
    case text(String)
    case binary(Data)
    /// `code` is nil when the socket ended without a close frame.
    case closed(code: UInt16?, reason: String)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .closed, .failed: return true
        case .text, .binary: return false
        }
    }
}

/// The sink handed to Rust. Callbacks arrive on a Rust thread, so all state
/// is behind a lock.
final class RealtimeStreamSink: RealtimeSink, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RealtimeEvent>.Continuation?

    init(continuation: AsyncStream<RealtimeEvent>.Continuation) {
        self.continuation = continuation
    }

    func onText(frame: String) { deliver(.text(frame)) }
    func onBinary(frame: Data) { deliver(.binary(frame)) }
    func onClosed(code: UInt16?, reason: String) { deliver(.closed(code: code, reason: reason)) }
    func onError(message: String) { deliver(.failed(message)) }

    // The yield happens UNDER the lock. Releasing it first lets a frame that
    // already passed the guard be yielded after a terminal from another
    // thread (measured: RealtimeStreamTests race leg, "text(38)" after
    // "failed"). `AsyncStream.Continuation.yield` never blocks, so holding
    // the lock across it cannot deadlock the Rust callback thread.
    private func deliver(_ event: RealtimeEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard let c = continuation else { return }
        c.yield(event)
        if event.isTerminal {
            continuation = nil
            c.finish()
        }
    }
}

enum RealtimeEvents {
    /// ~5 s of 20 ms audio frames, matching the Rust outbound queue cap.
    static let defaultBufferLimit = 256

    static func make(bufferLimit: Int = defaultBufferLimit)
        -> (sink: RealtimeStreamSink, events: AsyncStream<RealtimeEvent>,
            continuation: AsyncStream<RealtimeEvent>.Continuation)
    {
        let (events, continuation) = AsyncStream<RealtimeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit)))
        return (RealtimeStreamSink(continuation: continuation), events, continuation)
    }
}

struct RealtimeChannel {
    let session: RealtimeSession
    let events: AsyncStream<RealtimeEvent>
}

/// How a session is opened. The embedded core's `realtimeConnect` fits this
/// shape; a remote-gateway path can supply its own. Taking the closure instead
/// of a `ZeusCoreProtocol` keeps this file off the core-holder census
/// (SessionCapabilitiesTests.testNoViewHoldsACoreDirectly).
typealias RealtimeConnector = (RealtimeConnect, RealtimeSink) throws -> RealtimeSession

/// Open a realtime session and expose its inbound side as an `AsyncStream`.
/// Throws the connector's error unchanged; on a throw the stream is already
/// finished, so nothing is left dangling.
func openRealtime(_ conn: RealtimeConnect, via connect: RealtimeConnector,
                  bufferLimit: Int = RealtimeEvents.defaultBufferLimit) throws -> RealtimeChannel
{
    let (sink, events, continuation) = RealtimeEvents.make(bufferLimit: bufferLimit)
    let session: RealtimeSession
    do {
        session = try connect(conn, sink)
    } catch {
        continuation.finish()
        throw error
    }
    continuation.onTermination = { reason in
        if case .cancelled = reason { session.close() }
    }
    return RealtimeChannel(session: session, events: events)
}
