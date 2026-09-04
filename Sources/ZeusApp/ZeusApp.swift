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

    private let store: CommissionStoring

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

    var body: some Scene {
        WindowGroup {
            if let commission = state.commission {
                RootView(push: push)
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
                CommissioningView { result in
                    withAnimation(.easeInOut(duration: 0.45)) { state.commission(result) }
                }
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
