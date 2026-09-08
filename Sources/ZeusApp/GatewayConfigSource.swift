import Foundation
import Combine

/// The ONE current gateway configuration, shared by every surface that talks
/// to a gateway.
///
/// ## Why this type exists
///
/// Before it, `RootView.init` computed ONE resolution and captured it four
/// times — into the session engine's transport factory closure, and into a
/// `private let config` on each of `LinkMonitor`, `ApprovalsStore` and
/// `RouteCatalogStore`. A URL saved through the editor persisted to disk and
/// was read at the NEXT launch: four byte-sending surfaces stayed on the
/// launch host for the rest of the process.
///
/// Making `RootView.resolution` a `@State` would have been strictly worse.
/// It re-dates the five LABEL readers and none of the four senders, so the
/// screen would agree with the operator while the transport, the probe, the
/// approvals queue and the route catalogue all still spoke to the old host —
/// four precedences instead of one, and less visible than the honest
/// `APPLIES ON NEXT LAUNCH` caption it replaced.
///
/// ## Read per use is NOT sufficient, and the storage census cannot see it
///
/// A census that `private let config` reads 0 on the three observables proves
/// the freeze left the STORAGE. It says nothing about a freeze that already
/// happened:
///
///   * at INIT — all three derive their initial `state` from the config once
///     (`LinkMonitor` `.probing`/`.unconfigured`/`.embedded`,
///     `ApprovalsStore` and `RouteCatalogStore` their `.unconfigured` arms).
///     A source read per use leaves those labels on the launch verdict.
///   * inside a RUNNING TASK — `LinkMonitor.start()` binds the endpoint ONCE
///     into the poll loop and re-probes that binding forever. It is
///     idempotent by design (`guard pollTask == nil`), so a later `start()`
///     is a no-op: nothing short of a cancel moves the probe to a new host.
///
/// So the three do not merely READ this object, they OBSERVE it and re-derive
/// on change. That makes "did surface X follow the new URL" a property of
/// construction and of the change path, rather than of somebody remembering
/// to call a setter — four `reconfigure(config:)` methods were refused for
/// exactly that reason: a missed setter is invisible, and the surface simply
/// keeps working against the dead host.
///
/// ## Sole writer
///
/// `adopt(_:)` is the ONLY assignment to `resolution` in the whole project
/// (`AccessibilityTests` censuses the assignments). Its one production call
/// site is the re-resolve after a SAVE.
@MainActor
final class GatewayConfigSource: ObservableObject {

    /// THE current resolution. `@Published`, so `$resolution` is the change
    /// path the three observables subscribe to.
    @Published private(set) var resolution: GatewayConfig.Resolution

    var config: GatewayConfig { resolution.config }

    init(_ resolution: GatewayConfig.Resolution) {
        self.resolution = resolution
    }

    /// A source that never changes. TEST AND PREVIEW SUPPORT: it exists so a
    /// leg can construct an observable without a store, and a census asserts
    /// it has ZERO call sites in `Sources` — a production surface built on a
    /// fixed source is a re-freeze wearing a factory's name.
    static func fixed(_ config: GatewayConfig) -> GatewayConfigSource {
        GatewayConfigSource(GatewayConfig.Resolution(config: config, source: .unset))
    }

    /// THE ONE ASSIGNMENT SITE. Named rather than a settable property for the
    /// reason recorded at `Commission.recordDeployment`: a writer with a name
    /// has a call site a census can count.
    func adopt(_ next: GatewayConfig.Resolution) {
        resolution = next
    }
}
