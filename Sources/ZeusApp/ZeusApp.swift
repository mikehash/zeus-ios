import SwiftUI

@main
struct ZeusApp: App {
    /// Commissioning gates the console. `nil` means uncommissioned — the
    /// operator has not been through the flow, so there is no route, no
    /// callsign, and nothing for the console to be a console *of*.
    ///
    /// This is state, not navigation: the console is not "behind" the flow,
    /// it is unreachable without the value the flow produces.
    /// Seeded from `-zeusSeedCommission` in DEBUG only; `nil` in every
    /// release build and in any debug launch that does not pass the flag.
    @State private var commission: Commission? = LaunchArgs.seededCommission

    var body: some Scene {
        WindowGroup {
            if let commission {
                RootView()
                    .transition(.opacity)
                    // Carried so the ZEUS tab header can read `OPERATOR ·
                    // <callsign>` and the LINK pill can tell solo from
                    // enrolled. Unread today; wiring it is the M4 cut.
                    .environment(\.commission, commission)
            } else {
                CommissioningView { result in
                    withAnimation(.easeInOut(duration: 0.45)) { commission = result }
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
