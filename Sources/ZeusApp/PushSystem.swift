import Foundation
import UIKit
import UserNotifications

/// The real `UNUserNotificationCenter` / `UIApplication` implementation of
/// `NotificationAuthority`.
///
/// Kept in its own file, deliberately thin, and NOT unit-tested: every line
/// here is a call into a system framework whose behaviour depends on a
/// provisioning profile and a user decision. There is nothing here a test
/// could assert that would not be asserting UIKit. The logic that *can* be
/// guarded lives in `PushRegistrar.swift` and is guarded there.
struct SystemNotificationAuthority: NotificationAuthority {

    func authorizationStatus() async -> PushAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            // Provisional counts as authorized: it grants a real token and
            // delivers quietly. Treating it as notDetermined would re-prompt a
            // user who has already been granted quiet delivery.
            return .authorized
        @unknown default:
            // A future arm is NOT assumed permissive. Claiming authorization
            // for a status this build has never seen would be the widest
            // possible version of the defect this subsystem exists to avoid.
            return .notDetermined
        }
    }

    func requestAuthorization() async -> PushAuthorizationStatus {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .authorized : .denied
        } catch {
            // A throw here is not a user refusal. Reporting `denied` would
            // attribute a platform error to the operator and permanently
            // suppress the affordance.
            return .notDetermined
        }
    }

    @MainActor
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// The APNs callback surface.
///
/// SwiftUI has no `onRegisterForRemoteNotifications`, so a `UIApplicationDelegate`
/// is the ONLY path by which a device token can reach this app — there is no
/// pure-SwiftUI alternative. `@UIApplicationDelegateAdaptor` in `ZeusApp` is
/// what installs it.
///
/// The delegate holds no state of its own: it forwards to the registrar and
/// nothing else. A second copy of push state here would be a second writer to
/// the same fact, and the two would drift.
final class PushAppDelegate: NSObject, UIApplicationDelegate {

    /// Set by `ZeusApp` immediately after the adaptor constructs this.
    /// `weak` is wrong here — the registrar is owned by a `@StateObject` that
    /// outlives the delegate, but a strong reference from a UIKit singleton to
    /// a SwiftUI-owned object is the shorter-lived direction, so this is the
    /// side that holds strongly and is never cleared.
    @MainActor var registrar: PushRegistrar?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            registrar?.didRegister(tokenData: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MainActor.assumeIsolated {
            registrar?.didFailToRegister(error: error)
        }
    }
}
