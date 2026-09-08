import Foundation
import SwiftUI
import Combine

/// Real link-state observation — the source `RootView:90` and `NodesView:34`
/// did not have.
///
/// ## Why this file exists
///
/// Two sites shipped a link claim with nothing behind it:
///
///   * `RootView:90`  `statusLine: "LINKED · KITCHEN NODE"` — a string literal.
///     It read LINKED with the gateway unconfigured, unreachable, or refusing.
///   * `NodesView:34` `@State private var nodeOnline = true` — view-local, with
///     its own comment admitting *"nothing outside this view can do yet"*.
///
/// Both are a UI claiming a property of the world that no code measures. That
/// is the one defect class in the ship-layer list that ships a LIE to a user:
/// every other gap is a missing feature, this one is a present falsehood.
///
/// ## What is measured
///
/// `GET {base}/health` — chosen because it is the only probe target that is
/// both cheap and unauthenticated. Verified at `~/Zeus`:
/// `crates/zeus-api/src/public_paths.rs:33` lists `"/health"` in
/// `PUBLIC_EXACT`, and `handlers/chat_handlers.rs:160` is
/// `pub async fn health() -> Json<Value>` — no `State` extractor, so it
/// cannot 500 on a missing request extension the way the privileged routes do
/// in no-token mode.
///
/// That matters for the failure taxonomy below: probing an authenticated route
/// would make "gateway down" and "token wrong" the same observation, and the
/// pill would read REMOTE for a box that is up and reachable.
///
/// ## What is deliberately NOT measured
///
/// This is reachability of the CONFIGURED GATEWAY. It is not:
///   * whether a specific named node ("KITCHEN NODE") is up — the gateway
///     exposes no per-node liveness this app is wired to, so the node name is
///     still presentational and is now spelled from the endpoint host rather
///     than from a fiction.
///   * network interface state. `NWPathMonitor` answers "does this phone have
///     a route to anywhere", which is a different question and answers YES on
///     a cellular connection that cannot see a LAN gateway.
///
/// Naming the aperture here because a status pill is exactly the surface where
/// a narrower measurement gets read as a wider claim.
enum LinkState: Equatable {
    /// No gateway configured, or configured malformed. Distinct from
    /// unreachable: there is nothing to reach, which is a user-fixable
    /// configuration fact rather than a transient network one.
    case unconfigured

    /// A probe is in flight and no result has ever come back. Only ever the
    /// FIRST probe — subsequent probes retain the previous verdict, so the
    /// pill does not flicker through an intermediate state every poll.
    case probing

    /// The gateway runs IN THIS PROCESS. There is no link to measure.
    ///
    /// This arm exists because neither neighbour could tell the truth about
    /// `.local`: `.unconfigured` says "no gateway configured" — false, there is
    /// one and it is running — and `.linked` carries `host` and `ms`, two
    /// values no probe produced and which would have to be invented. A
    /// fabricated round-trip on a status pill is the exact defect the
    /// `t-12min` literal was deleted for.
    ///
    /// It is also NOT probed: `start()` opens no poll loop for it. A local core
    /// has no endpoint, and a health check against yourself measures nothing.
    case embedded

    /// `/health` answered 2xx. Round-trip in milliseconds, for the status line.
    case linked(host: String, ms: Int)

    /// Reached the network and did not get a 2xx, or did not reach it at all.
    case unreachable(host: String, reason: String)

    /// The single predicate the views branch on. Kept as one computed property
    /// rather than open-coded `if case` at each site, so a fifth state cannot
    /// be added without this switch failing to compile.
    var isLinked: Bool {
        switch self {
        case .linked:                                   return true
        // TRUE, and it is the one arm where the word needs defending: nothing
        // was measured. `isLinked` gates whether the console can talk to a
        // core, and an embedded core is reachable BY CONSTRUCTION — it is in
        // this address space. Returning false would disable the console
        // against a working gateway.
        case .embedded:                                 return true
        case .unconfigured, .probing, .unreachable:     return false
        }
    }

    /// `SessionView`'s header line. Replaces the `RootView:90` literal.
    ///
    /// Uppercased here rather than by the view, matching the prototype's
    /// convention of shipping display-cased data (see `Tab.label`).
    var statusLine: String {
        switch self {
        case .unconfigured:
            return "NO GATEWAY · SET ZEUS_GATEWAY_URL"
        // Names WHERE the core is, and deliberately reports no latency: the
        // other three informative arms carry a measurement, and this one has
        // none to carry.
        case .embedded:
            return "LOCAL · ON THIS PHONE"
        case .probing:
            return "LINKING…"
        case .linked(let host, let ms):
            return "LINKED · \(host.uppercased()) · \(ms)MS"
        case .unreachable(let host, let reason):
            return "REMOTE · \(host.uppercased()) · \(reason.uppercased())"
        }
    }

    /// The NODES row subtitle. Replaces two literals, one of which
    /// (`"unreachable · last seen t-12min"`) invented a timestamp nothing
    /// recorded — a fabricated observation, not merely a placeholder.
    var subtitle: String {
        switch self {
        case .unconfigured:
            return "no gateway configured"
        case .embedded:
            return "running on this phone"
        case .probing:
            return "probing…"
        case .linked(let host, let ms):
            return "\(host) · /health 200 · \(ms)ms"
        case .unreachable(let host, let reason):
            return "\(host) · \(reason)"
        }
    }

    /// The NODES pill. `LINKED`/`REMOTE` are the prototype's two words
    /// (`NodesView:133`); the other two arms are states the prototype never
    /// modelled because it never measured anything.
    var badgeText: String {
        switch self {
        case .unconfigured:  return "UNSET"
        case .probing:       return "LINKING"
        case .linked:        return "LINKED"
        // NOT "LINKED": that word means a remote gateway answered a probe, and
        // reusing it here would make the two indistinguishable on the one
        // surface whose entire job is telling them apart.
        case .embedded:      return "LOCAL"
        case .unreachable:   return "REMOTE"
        }
    }

    /// Pill colour. `unconfigured` is DIM rather than `warn`: an unset gateway
    /// is a state the user has not acted on, not a fault the app detected, and
    /// colouring it amber would report a problem where there is only an
    /// absence.
    var badgeColor: Color {
        switch self {
        case .unconfigured:  return Theme.w(0.35)
        case .probing:       return Theme.info
        case .linked:        return Theme.ok
        case .embedded:      return Theme.ok
        case .unreachable:   return Theme.warn
        }
    }
}

// MARK: - Probe seam

/// One probe, one verdict. A protocol so the monitor can be driven by a
/// scripted probe in tests without a server, a socket, or a sleep.
///
/// `Sendable` because the monitor calls it from a detached context;
/// `SessionTransport:17` carries the same refinement for the same reason.
protocol LinkProbe: Sendable {
    func probe(_ endpoint: GatewayConfig.Endpoint) async -> LinkState
}

/// The real one: `GET {base}/health`, short timeout, no credential.
///
/// The token is NOT sent even when configured. `/health` is in `PUBLIC_EXACT`,
/// so a credential adds nothing — and omitting it means a stale or wrong token
/// cannot turn a healthy gateway into a REMOTE pill. Auth failures belong to
/// the chat path, where they are actionable.
struct HTTPLinkProbe: LinkProbe {
    /// Seconds. Deliberately short: this runs on a poll and a probe that
    /// outlives its own interval would queue verdicts behind each other.
    let timeout: TimeInterval

    init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    static func healthURL(base: URL) -> URL {
        base.appendingPathComponent("health")
    }

    func probe(_ endpoint: GatewayConfig.Endpoint) async -> LinkState {
        let host = endpoint.url.host ?? endpoint.url.absoluteString
        var request = URLRequest(url: Self.healthURL(base: endpoint.url))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        // A cached 200 would report a gateway that died an hour ago as live.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(host: host, reason: "no http response")
            }
            guard (200...299).contains(http.statusCode) else {
                // A non-2xx from /health means something answered on that
                // address and it was not a healthy Zeus gateway — a proxy, a
                // captive portal, a different service. Distinct from silence.
                return .unreachable(host: host, reason: "http \(http.statusCode)")
            }
            return .linked(host: host, ms: ms)
        } catch {
            return .unreachable(host: host, reason: Self.shortReason(error))
        }
    }

    /// `URLError.localizedDescription` is a sentence; the pill has room for a
    /// phrase. Mapped rather than truncated so the words are chosen, not cut.
    static func shortReason(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return "failed" }
        switch urlError.code {
        case .timedOut:                return "timeout"
        case .cannotConnectToHost:     return "refused"
        case .cannotFindHost:          return "no host"
        case .notConnectedToInternet:  return "offline"
        case .networkConnectionLost:   return "link lost"
        case .secureConnectionFailed:  return "tls failed"
        default:                       return "unreachable"
        }
    }
}

// MARK: - Monitor

/// Polls the probe and publishes the verdict.
///
/// `@MainActor` for the same reason `SessionEngine` is: every reader is a
/// SwiftUI view, and a published property mutated off the main actor is a
/// runtime warning today and an error under strict concurrency.
@MainActor
final class LinkMonitor: ObservableObject {
    @Published private(set) var state: LinkState

    private let probe: LinkProbe
    /// THE shared current config. Not a `GatewayConfig` copy: a copy taken at
    /// construction is the launch-host freeze this type used to hold, and the
    /// storage census in `AccessibilityTests` asserts it is gone.
    private let source: GatewayConfigSource
    private var config: GatewayConfig { source.config }
    private let interval: Duration
    private var pollTask: Task<Void, Never>?
    private var follow: AnyCancellable?

    /// Whether the OWNER wants a poll running, as distinct from whether one
    /// IS running. `start()` sets it before its guards, so an unconfigured
    /// launch that later adopts a URL still restarts; `suspend()`/`stop()`
    /// clear it, so a backgrounded app does not silently resume polling
    /// because someone saved a URL.
    private var wantsPolling = false

    /// Config is resolved ONCE at construction, not per poll. The environment
    /// cannot change under a running app, and re-resolving per poll would make
    /// every verdict depend on a read that always returns the same thing —
    /// work whose only possible effect is a bug.
    /// `config` has NO DEFAULT. A default here would call the ENV-ONLY half
    /// of resolution (`resolveFromEnvironment`) and silently bypass the
    /// commission the operator chose — and worse, bypass the seeded
    /// `InMemoryCommissionStore` that `ZeusApp.swift` builds for capture and
    /// test launches, so a screenshot would photograph a config the seed
    /// never wrote. Required parameter, so the compiler enumerates the set.
    init(source: GatewayConfigSource,
         probe: LinkProbe = HTTPLinkProbe(),
         interval: Duration = .seconds(10)) {
        self.source = source
        self.probe = probe
        self.interval = interval
        // The initial value is a fact about CONFIGURATION, which is known
        // synchronously — so an unconfigured build never shows LINKING…, a
        // state it could never leave.
        self.state = Self.state(for: source.config)
        // OBSERVE, do not merely read. Reading the source per use would move
        // the REQUESTS and leave this label on the launch verdict, and the
        // poll loop below binds its endpoint once — see the file header.
        self.follow = source.$resolution
            .dropFirst()
            .sink { [weak self] next in
                guard let self else { return }
                Task { @MainActor in await self.adopt(next.config) }
            }
    }

    /// The pill's state as a pure function of configuration — known
    /// synchronously, so it is derivable at init AND re-derivable on change
    /// from the same expression. Two switches would be two chances to move
    /// one arm and not the other.
    static func state(for config: GatewayConfig) -> LinkState {
        switch config {
        case .resolved:                 return .probing
        // No poll loop opens for this arm (`start()` guards on `.resolved`),
        // so this is a TERMINAL state, not an initial one. That is correct:
        // an in-process core has nothing to probe, and the pill should never
        // move off it.
        case .local:                    return .embedded
        case .absent, .malformed:       return .unconfigured
        }
    }

    /// Follow a new configuration: CANCEL the poll, re-derive the label, and
    /// re-open the loop against the new endpoint.
    ///
    /// 🔴 The cancel is the load-bearing half. `start()` is idempotent
    /// (`guard pollTask == nil`) and the running loop closed over its
    /// endpoint ONCE, so calling `start()` again without stopping first is a
    /// no-op that leaves the probe on the dead host — with a pill that says
    /// LINKED, because the old host is very often still reachable. A leg on
    /// `state` alone cannot see that; `testAdoptingANewURLMovesTheProbe`
    /// asserts on the endpoint the probe was HANDED.
    func adopt(_ next: GatewayConfig) async {
        let resume = wantsPolling
        await stop()
        state = Self.state(for: next)
        if resume { start() }
    }

    /// Idempotent. A second `start()` does not stack a second poll loop —
    /// `.task` can re-fire on view identity changes, and two loops would halve
    /// the effective interval invisibly.
    func start() {
        wantsPolling = true
        guard pollTask == nil else { return }
        guard case .resolved(let endpoint) = config else { return }

        pollTask = Task { [weak self, probe, interval] in
            while !Task.isCancelled {
                let verdict = await probe.probe(endpoint)
                guard let self, !Task.isCancelled else { return }
                self.state = verdict
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Awaited cancellation. The sync form cancelled the task and returned
    /// immediately, so a probe already in flight when `stop()` landed would
    /// complete and increment after the caller read the count — the 4-vs-3
    /// straggler in `testStopHaltsPolling`. Awaiting `task?.value` means the
    /// in-flight probe finishes, the loop observes the cancel, and only THEN
    /// does this return — so a count read after `stop()` is final by
    /// construction, not by sleep.
    ///
    /// Sync call sites wrap in `Task { await monitor.stop() }`; `deinit`
    /// keeps plain `cancel()` — it asserts nothing and cannot await.
    func stop() async {
        wantsPolling = false
        let task = pollTask
        pollTask = nil
        task?.cancel()
        await task?.value
    }

    /// Background transition: stop polling AND invalidate the verdict.
    ///
    /// 🔴 The invalidation is the load-bearing half, and stopping alone would
    /// be the `t-12min` defect wearing a different costume. A suspended app
    /// keeps its last rendered frame; iOS shows it in the app switcher and
    /// again for the instant before the first foreground frame draws. So a
    /// monitor that merely stops polling leaves `LINKED · 12MS` on screen
    /// across a suspend of arbitrary length — minutes, hours, a flight — and
    /// that reading is *stale by construction*: no probe has run since it was
    /// taken, and the app has no way to know whether it is still true.
    ///
    /// A measurement that outlives the process's ability to re-take it is
    /// indistinguishable, on screen, from a fresh one. `.probing` is the only
    /// honest state to hold in the background: it says "no current verdict"
    /// rather than asserting a remembered one.
    ///
    /// Unconfigured is exempt — it is not a measurement, it is the absence of
    /// a target, and it cannot go stale because nothing was ever probed.
    /// Cancels without awaiting: `suspend()` is the scene-phase call site —
    /// it runs synchronously on `.background` and cannot block on the loop.
    /// The one in-flight probe it may leave behind is bounded (a single
    /// interval) and is asserted allowed in `testSuspendStopsPolling`.
    func suspend() {
        wantsPolling = false
        pollTask?.cancel()
        pollTask = nil
        if case .unconfigured = state { return }
        // Same exemption, same reason: `.embedded` is not a measurement that
        // can go stale. The core does not stop existing while the app is
        // backgrounded, and showing LINKING… for it would advertise a probe
        // that never runs.
        if case .embedded = state { return }
        state = .probing
    }

    /// Foreground transition: probe immediately, then resume the interval.
    ///
    /// The immediate probe is not an optimisation — it is what bounds the
    /// window in which `.probing` is displayed. Calling `start()` alone would
    /// also probe first (the loop's body probes before it sleeps), so this is
    /// deliberately the same shape; `resume` exists as a named seam so the
    /// scene-phase call site reads as a lifecycle event rather than as an
    /// incidental `start()`.
    func resume() {
        start()
    }

    /// One probe, awaited. The test seam and the pull-to-refresh path: it
    /// returns only after the verdict has been published, so a caller can
    /// assert on `state` without a settle loop.
    func probeOnce() async {
        guard case .resolved(let endpoint) = config else {
            state = .unconfigured
            return
        }
        state = await probe.probe(endpoint)
    }

    deinit { pollTask?.cancel() }
}
