import SwiftUI

/// Owns the one decision the app makes at launch: console or commissioning.
///
/// Split out of `ZeusApp` because `App` conformers are not directly testable —
/// there is no way to instantiate a `@main` scene and observe it — so the
/// restore logic that decides which branch renders would have been guardable
/// only through the process boundary. As a plain `ObservableObject` it is
/// exercised directly, with an injected store, in-process.
@MainActor
final class AppState: ObservableObject {
    /// `nil` means uncommissioned: the operator has not been through the flow,
    /// so there is no route, no callsign, and nothing for the console to be a
    /// console *of*. This is state, not navigation — the console is not
    /// "behind" the flow, it is unreachable without the value the flow
    /// produces.
    @Published private(set) var commission: Commission?

    /// Exposed READ-ONLY (`let`, non-private) because `RootView` must hand the
    /// same store to `GatewayConfig.resolve(from:store:)` that this object was
    /// built with. Read-only and not `var`: a second writer would mean two
    /// pictures of one commission, and the write path stays `commission(_:)` /
    /// `decommission()` on this type. The capture harness seeds an
    /// `InMemoryCommissionStore` here, and that is precisely the object the
    /// resolution seam has to see.
    let store: CommissionStoring

    /// Resolution order, and each rung is deliberate:
    ///
    /// 1. **DEBUG launch argument** — a screenshot run must photograph the
    ///    screen the flag names, regardless of what is on disk, or the
    ///    artefact depends on the simulator's history rather than on the
    ///    flag. It also must not *write*, which is why the seeded path is
    ///    backed by `InMemoryCommissionStore`.
    /// 2. **Persisted commission** — the cold-start restore this type exists
    ///    for.
    /// 3. **`nil`** — run the flow.
    init(store: CommissionStoring? = nil) {
        if let seeded = LaunchArgs.seededCommission {
            self.store = store ?? InMemoryCommissionStore(seed: seeded)
            self.commission = seeded
            return
        }
        let resolved = store ?? UserDefaultsCommissionStore()
        self.store = resolved
        self.commission = resolved.load()
    }

    /// Called once, when commissioning completes. Writes **before** publishing
    /// so a crash in the same turn as the transition cannot leave the operator
    /// looking at a console that will be gone next launch — the persisted
    /// value is the authority, and the in-memory one is the copy.
    func commission(_ value: Commission) {
        store.save(value)
        commission = value
    }

    /// Forget the operator entirely: clears the persisted record and returns
    /// the app to commissioning. Wired to NODES → REVOKE ACCESS.
    func decommission() {
        store.clear()
        commission = nil
    }
}

@main
struct ZeusApp: App {
    @StateObject private var state = AppState()

    /// Push. Owned here rather than in `RootView` because the APNs token
    /// arrives on the app delegate, which exists for the process lifetime —
    /// a registrar owned by a view would miss a token delivered before that
    /// view was constructed.
    @StateObject private var push = PushRegistrar(authority: SystemNotificationAuthority())

    /// The ONLY path by which a device token can reach a SwiftUI app: there is
    /// no `onRegisterForRemoteNotifications` scene modifier.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    /// THE key store — ONE instance, handed to BOTH arms of the `if let` below.
    ///
    /// It was two. `CommissioningView` built one and `RootView.init` built
    /// another, and on the KEYCHAIN arm that is invisible: two instances share
    /// state through the Keychain, so production behaved. On the IN-MEMORY arm
    /// (`useInMemoryTokens` — the test and capture launch) they are two
    /// dictionaries, so a key typed at ROUTES was written into a store the arm
    /// never read, and the session armed `NO KEY FOR <label>` on a key the
    /// operator had just entered. That is the path the simulator frames drive.
    ///
    /// Owned here because this is the only object that outlives BOTH arms: the
    /// `if let` swaps `CommissioningView` for `RootView` the moment the record
    /// gains a commission, and a store owned by either arm dies with it.
    private let keys: ProviderKeyStoring = LaunchArgs.useInMemoryTokens
        ? InMemoryProviderKeyStore()
        : ProviderKeyStore()

    var body: some Scene {
        WindowGroup {
            if let commission = state.commission {
                RootView(store: state.store, push: push, keys: keys)
                    .transition(.opacity)
                    // Carried so the ZEUS tab header can read `OPERATOR ·
                    // <callsign>` and the LINK pill can tell solo from
                    // enrolled.
                    .environment(\.commission, commission)
                    .environmentObject(state)
                    // Hand the registrar to the delegate as soon as a scene
                    // exists. Doing it here rather than in the delegate's own
                    // init is what keeps ONE registrar: the delegate is
                    // constructed by UIKit and cannot reach the @StateObject.
                    .onAppear { pushDelegate.registrar = push }
            } else {
                CommissioningView(
                    onComplete: { result in
                        withAnimation(.easeInOut(duration: 0.45)) { state.commission(result) }
                    },
                    keys: keys
                )
            }
        }
    }
}

private struct CommissionKey: EnvironmentKey {
    static let defaultValue = Commission()
}

extension EnvironmentValues {
    var commission: Commission {
        get { self[CommissionKey.self] }
        set { self[CommissionKey.self] = newValue }
    }
}
