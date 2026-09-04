import Foundation
import SwiftUI

/// Push notification state — and, more importantly, the difference between
/// *permission granted* and *actually registered*.
///
/// ## The defect this file exists to not ship
///
/// The obvious model is a `Bool`: the user tapped Allow, so show "ALERTS ON".
/// That is `LINKED · KITCHEN NODE` one subsystem over. `UNUserNotificationCenter`
/// authorization is a decision by the *user*; it says nothing about whether
/// APNs ever issued this build a device token. A build with no
/// `aps-environment` entitlement can reach `.authorized` and never receive a
/// token — the permission sheet appears, the user taps Allow, and every alert
/// silently goes nowhere.
///
/// So authorization and registration are separate arms, and **only a real
/// token renders a subscribed-looking surface.**
///
/// ## What is measurable on this box, and what is not
///
/// MEASURABLE, and guarded below: the state machine, the permission mapping,
/// the token formatting, the refusal to claim registration without a token,
/// and the aps-environment diagnosis.
///
/// NOT MEASURABLE HERE, by anyone: whether APNs delivers a payload. There is
/// no paid team wired to this project, no device, and `simctl push` fabricates
/// a payload *locally* — it proves the handler runs, it does not prove
/// registration. This file therefore never claims "push works". It claims the
/// app asks honestly, reports what it was told, and does not invent a
/// subscription it cannot demonstrate.
enum PushState: Equatable {

    /// The permission sheet has not been shown. The only state from which
    /// `request()` does anything.
    case notDetermined

    /// The user declined, or later revoked in Settings. Terminal from the
    /// app's side: iOS will not re-prompt, so the only honest affordance is a
    /// deep link to Settings.
    case denied

    /// 🔴 THE LOAD-BEARING ARM. The user granted permission and APNs has not
    /// (yet, or ever) returned a device token.
    ///
    /// This is a *real steady state*, not a transient: on a build without the
    /// `aps-environment` entitlement it is where the app permanently lives.
    /// Collapsing it into "authorized" is precisely the lie — it renders as
    /// subscribed while nothing can arrive.
    case authorizedAwaitingToken

    /// APNs issued a token. The ONLY arm any surface may render as subscribed,
    /// because it is the only one backed by a value the app was handed rather
    /// than a permission it was granted.
    case registered(tokenSuffix: String)

    /// Registration failed and APNs said why. Kept distinct from `denied`:
    /// the user said yes and the *platform* refused, which is a developer
    /// fault and must not read as a user choice.
    case registrationFailed(reason: String)
}

// MARK: - Derivations
//
// Every one is a `static func` over its inputs rather than a computed property
// reading view state. A SwiftUI body is not observable in-process, so a
// derivation that lives inside one is guardable only by screenshot — which is
// how the three literal-status defects in this app survived as long as they
// did. Lifting them costs nothing and makes the mutation battery possible.

extension PushState {

    /// The single predicate every surface must gate on. Deliberately NOT
    /// `case .authorized`-shaped: `authorizedAwaitingToken` is authorized and
    /// is not subscribed.
    var isSubscribed: Bool {
        if case .registered = self { return true }
        return false
    }

    /// The ALERTS cell value. `PENDING` rather than `ON` for the awaiting arm,
    /// and the difference is the whole point of the file.
    var badgeText: String { Self.badgeText(for: self) }

    static func badgeText(for state: PushState) -> String {
        switch state {
        case .notDetermined:           return "OFF"
        case .denied:                  return "BLOCKED"
        case .authorizedAwaitingToken: return "PENDING"
        case .registered:              return "ON"
        case .registrationFailed:      return "FAILED"
        }
    }

    /// The detail line. Never a fabricated value: where the token is unknown
    /// the string says what is missing, it does not print a plausible suffix.
    var detailLine: String { Self.detailLine(for: self) }

    static func detailLine(for state: PushState) -> String {
        switch state {
        case .notDetermined:
            return "notifications not requested"
        case .denied:
            return "declined — re-enable in Settings"
        case .authorizedAwaitingToken:
            // Says the true thing, which is uncomfortable and correct: the
            // user granted permission and the app has nothing to show for it.
            return "allowed · no device token yet"
        case .registered(let suffix):
            return "token ·\(suffix)"
        case .registrationFailed(let reason):
            return reason
        }
    }

    static func badgeColor(for state: PushState) -> Color {
        switch state {
        case .notDetermined:           return Theme.w(0.35)
        case .denied:                  return Theme.warn
        case .authorizedAwaitingToken: return Theme.info
        case .registered:              return Theme.ok
        case .registrationFailed:      return Theme.warn
        }
    }
}

// MARK: - Token formatting

enum PushToken {

    /// Last four bytes of the device token, uppercased hex.
    ///
    /// A device token is a credential: whole, in a log or on screen, it is
    /// enough for anyone reading over a shoulder to address this device. Eight
    /// hex characters is enough for an operator to tell two devices apart and
    /// not enough to push to either.
    ///
    /// Returns `nil` for empty data rather than an empty string — an empty
    /// suffix would render `token ·` with a dangling separator, the exact
    /// shape already removed from the session header.
    static func suffix(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return data.suffix(4)
            .map { String(format: "%02X", $0) }
            .joined()
    }
}

// MARK: - Authority seam

/// The `UNUserNotificationCenter` surface, behind a protocol so the state
/// machine is drivable without a permission sheet, a device, or an entitlement.
///
/// `Sendable` for the same reason `LinkProbe:141` is: the registrar awaits it
/// off the main actor.
protocol NotificationAuthority: Sendable {
    /// The system's current setting. Read at every foreground, because the
    /// user can revoke in Settings while the app is backgrounded and the app
    /// is never told.
    func authorizationStatus() async -> PushAuthorizationStatus
    /// Shows the sheet. Returns the resulting status, not a `Bool` — a `Bool`
    /// cannot distinguish "declined" from "already denied, sheet never shown".
    func requestAuthorization() async -> PushAuthorizationStatus
    /// Asks APNs for a token. Fire-and-forget: the answer arrives on the app
    /// delegate, not as a return value.
    @MainActor func registerForRemoteNotifications()
}

/// Mirrors the arms of `UNAuthorizationStatus` this app acts on. A local enum
/// rather than the framework type so tests do not need to fabricate a
/// `UNNotificationSettings`, which has no public initialiser.
enum PushAuthorizationStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

// MARK: - Registrar

/// Owns push state for the app. One instance, injected into the views that
/// render it, so two surfaces cannot disagree about whether alerts are live —
/// the same shape as `LinkMonitor` and for the same reason.
@MainActor
final class PushRegistrar: ObservableObject {

    @Published private(set) var state: PushState = .notDetermined

    private let authority: NotificationAuthority

    init(authority: NotificationAuthority) {
        self.authority = authority
    }

    /// Reconcile with the system. Called on foreground.
    ///
    /// 🔴 The `.authorized` arm does NOT clobber an existing `registered`
    /// state. Without that guard, every foreground would demote a
    /// successfully-registered app back to `authorizedAwaitingToken` — the
    /// token is held by us, not by `UNUserNotificationCenter`, so the system
    /// status can never confirm it. Reading a narrower source and overwriting
    /// a wider fact with it is the same class as the four-state probe folding
    /// to two.
    func refresh() async {
        switch await authority.authorizationStatus() {
        case .notDetermined:
            state = .notDetermined
        case .denied:
            // Deliberately DOES clobber `registered`: a revoked permission
            // means the token is dead, and continuing to render ON because we
            // still hold bytes would be a subscription claim with nothing
            // behind it.
            state = .denied
        case .authorized:
            if case .registered = state { return }
            if case .registrationFailed = state { return }
            state = .authorizedAwaitingToken
            authority.registerForRemoteNotifications()
        }
    }

    /// Show the permission sheet. Only from `notDetermined` — iOS silently
    /// no-ops a second request, so calling it from `denied` would produce a
    /// button that does nothing and looks broken.
    func request() async {
        guard state == .notDetermined else { return }
        switch await authority.requestAuthorization() {
        case .authorized:
            state = .authorizedAwaitingToken
            authority.registerForRemoteNotifications()
        case .denied:
            state = .denied
        case .notDetermined:
            // The sheet was dismissed without a choice. Stay put so the
            // affordance remains offerable; do not invent a refusal.
            state = .notDetermined
        }
    }

    /// APNs returned a token. The only transition into a subscribed surface.
    func didRegister(tokenData: Data) {
        guard let suffix = PushToken.suffix(tokenData) else {
            // Empty token data is a platform anomaly, not a success. Rendering
            // ON here would be a subscribed claim backed by zero bytes.
            state = .registrationFailed(reason: "empty device token")
            return
        }
        state = .registered(tokenSuffix: suffix)
    }

    /// APNs refused.
    ///
    /// Error 3000 / "no valid 'aps-environment' entitlement string found" is
    /// the build-configuration failure, and it is worth naming distinctly:
    /// it is the exact case where the user sees a permission sheet, taps
    /// Allow, and nothing can ever arrive. Diagnosing it from the error APNs
    /// returns is a MEASUREMENT — the alternative, a compile-time flag
    /// asserting the entitlement is present, would be an assumption wearing a
    /// measurement's clothes.
    func didFailToRegister(error: Error) {
        let text = String(describing: error).lowercased()
        if text.contains("aps-environment") {
            state = .registrationFailed(reason: "build has no APNs entitlement")
        } else {
            state = .registrationFailed(reason: "APNs registration failed")
        }
    }
}
