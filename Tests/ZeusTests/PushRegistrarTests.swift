import XCTest
@testable import Zeus

/// A scripted `NotificationAuthority`. Records whether APNs registration was
/// asked for — the observable that separates "we told the user yes" from "we
/// actually asked the platform".
///
/// `@unchecked Sendable` with a lock for the same reason `SessionIDBox`
/// carries it (`HTTPTransport.swift:17`): the protocol is `Sendable` because
/// the registrar awaits it off the main actor.
final class ScriptedAuthority: NotificationAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: PushAuthorizationStatus
    private var _requestResult: PushAuthorizationStatus
    private var _registerCalls = 0

    init(status: PushAuthorizationStatus, requestResult: PushAuthorizationStatus = .denied) {
        self._status = status
        self._requestResult = requestResult
    }

    var registerCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _registerCalls
    }

    func setStatus(_ s: PushAuthorizationStatus) {
        lock.lock(); defer { lock.unlock() }
        _status = s
    }

    func authorizationStatus() async -> PushAuthorizationStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    func requestAuthorization() async -> PushAuthorizationStatus {
        lock.lock(); defer { lock.unlock() }
        _status = _requestResult
        return _requestResult
    }

    @MainActor func registerForRemoteNotifications() {
        lock.lock(); defer { lock.unlock() }
        _registerCalls += 1
    }
}

@MainActor
final class PushRegistrarTests: XCTestCase {

    // MARK: - The defect this subsystem exists to not ship

    /// 🔴 THE CENTRAL LEG. Permission granted, no token — the state a build
    /// with no `aps-environment` entitlement lives in permanently.
    ///
    /// VACUITY FLOOR first: assert the request actually moved the state, so
    /// this cannot pass against a registrar that never transitioned at all.
    func testAuthorizedWithoutATokenIsNotSubscribed() async {
        let auth = ScriptedAuthority(status: .notDetermined, requestResult: .authorized)
        let reg = PushRegistrar(authority: auth)

        await reg.request()

        // FLOOR: the request did something.
        XCTAssertNotEqual(reg.state, .notDetermined,
            "VACUITY FLOOR: if request() left the state untouched, every " +
            "assertion below would pass against a registrar that does nothing.")
        XCTAssertEqual(reg.state, .authorizedAwaitingToken)

        // The claim.
        XCTAssertFalse(reg.state.isSubscribed,
            "authorization is a USER decision; it says nothing about whether " +
            "APNs issued a token. Rendering this as subscribed is the same " +
            "defect as a hardcoded LINKED pill: a claim about the world with " +
            "nothing measured behind it.")
        XCTAssertEqual(reg.state.badgeText, "PENDING")
        XCTAssertNotEqual(reg.state.badgeText, "ON")
    }

    /// The positive half — without it the leg above is satisfied by an
    /// `isSubscribed` that returns `false` unconditionally.
    func testOnlyARealTokenIsSubscribed() async {
        let auth = ScriptedAuthority(status: .notDetermined, requestResult: .authorized)
        let reg = PushRegistrar(authority: auth)
        await reg.request()
        XCTAssertFalse(reg.state.isSubscribed)

        reg.didRegister(tokenData: Data([0xDE, 0xAD, 0xBE, 0xEF]))

        XCTAssertTrue(reg.state.isSubscribed,
            "VACUITY: isSubscribed must be capable of returning true, or the " +
            "not-subscribed assertions are vacuous.")
        XCTAssertEqual(reg.state, .registered(tokenSuffix: "DEADBEEF"))
        XCTAssertEqual(reg.state.badgeText, "ON")
    }

    /// Exhaustive: NO state other than `.registered` may read as subscribed.
    /// Written over a literal list so a new arm has to be added here
    /// consciously.
    func testNoUnregisteredStateReadsAsSubscribed() {
        let unsubscribed: [PushState] = [
            .notDetermined,
            .denied,
            .authorizedAwaitingToken,
            .registrationFailed(reason: "build has no APNs entitlement"),
        ]
        XCTAssertEqual(unsubscribed.count, 4, "VACUITY FLOOR: the list is non-empty.")
        for s in unsubscribed {
            XCTAssertFalse(s.isSubscribed, "\(s) must not read as subscribed")
            XCTAssertNotEqual(PushState.badgeText(for: s), "ON",
                "\(s) must not render the subscribed badge")
        }
    }

    // MARK: - Token handling

    func testTokenSuffixIsTheLastFourBytesUppercaseHex() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0xAB, 0xCD, 0xEF, 0x0F])
        XCTAssertEqual(PushToken.suffix(data), "ABCDEF0F")
    }

    /// The short-token arm: fewer than four bytes returns what exists rather
    /// than padding. `suffix(4)` on a 2-byte Data is 2 bytes — asserted so
    /// "take the last four" and "take everything" are known to differ.
    func testShortTokenRendersWhole() {
        XCTAssertEqual(PushToken.suffix(Data([0x0A, 0x0B])), "0A0B")
        XCTAssertNotEqual(PushToken.suffix(Data([0x0A, 0x0B])),
                          PushToken.suffix(Data([0x01, 0x02, 0x0A, 0x0B])),
            "VACUITY: the two must differ, or the truncation assertion above " +
            "is satisfied by a function that never truncates.")
    }

    /// An empty token is a platform anomaly, not a success. The dangling-
    /// separator defect (`token ·`) is the same one removed from the session
    /// header at 66ac410.
    func testEmptyTokenDataIsAFailureNotASubscription() {
        let auth = ScriptedAuthority(status: .authorized)
        let reg = PushRegistrar(authority: auth)

        reg.didRegister(tokenData: Data())

        XCTAssertFalse(reg.state.isSubscribed)
        XCTAssertEqual(reg.state, .registrationFailed(reason: "empty device token"))
        XCTAssertFalse(reg.state.detailLine.hasSuffix("·"),
            "no dangling separator: a rendered `token ·` looks like a value " +
            "that failed to print rather than an absent one.")
    }

    // MARK: - Refresh reconciliation

    /// 🔴 A foreground must not demote a registered app. The system status
    /// cannot confirm a token — only we hold it — so overwriting a wider fact
    /// with a narrower source loses it every time the user switches apps.
    func testRefreshDoesNotDemoteARegisteredApp() async {
        let auth = ScriptedAuthority(status: .authorized)
        let reg = PushRegistrar(authority: auth)
        reg.didRegister(tokenData: Data([0x11, 0x22, 0x33, 0x44]))
        XCTAssertTrue(reg.state.isSubscribed, "VACUITY FLOOR: registered before refresh.")

        await reg.refresh()

        XCTAssertEqual(reg.state, .registered(tokenSuffix: "11223344"),
            "a foreground read of UNUserNotificationCenter cannot see the " +
            "device token, so treating .authorized as authoritative would " +
            "silently un-register the app on every app switch.")
    }

    /// The opposite arm, and it MUST clobber: a revoked permission kills the
    /// token, and continuing to render ON because we still hold bytes is a
    /// subscription claim with nothing behind it.
    func testRevokedPermissionClobbersARegisteredState() async {
        let auth = ScriptedAuthority(status: .authorized)
        let reg = PushRegistrar(authority: auth)
        reg.didRegister(tokenData: Data([0x11, 0x22, 0x33, 0x44]))
        XCTAssertTrue(reg.state.isSubscribed, "VACUITY FLOOR: registered before revoke.")

        auth.setStatus(.denied)
        await reg.refresh()

        XCTAssertEqual(reg.state, .denied)
        XCTAssertFalse(reg.state.isSubscribed)
    }

    /// Refresh on an authorized-but-tokenless app re-asks APNs. Without this
    /// the awaiting state is terminal and a transient APNs failure is never
    /// retried.
    func testRefreshAsksAPNsWhenAuthorizedWithoutAToken() async {
        let auth = ScriptedAuthority(status: .authorized)
        let reg = PushRegistrar(authority: auth)
        XCTAssertEqual(auth.registerCalls, 0, "VACUITY FLOOR: nothing asked yet.")

        await reg.refresh()

        XCTAssertEqual(reg.state, .authorizedAwaitingToken)
        XCTAssertEqual(auth.registerCalls, 1,
            "granting permission without calling registerForRemoteNotifications " +
            "produces an app that is authorized forever and never receives " +
            "anything — the permission sheet is not the registration.")
    }

    /// A failure is sticky across foregrounds. Without this, every app switch
    /// resets an entitlement-less build to PENDING and the diagnosis is lost.
    func testRefreshDoesNotClearADiagnosedFailure() async {
        let auth = ScriptedAuthority(status: .authorized)
        let reg = PushRegistrar(authority: auth)
        reg.didFailToRegister(error: NSError(
            domain: "NSCocoaErrorDomain", code: 3000,
            userInfo: [NSLocalizedDescriptionKey:
                "no valid 'aps-environment' entitlement string found for application"]))
        XCTAssertEqual(reg.state, .registrationFailed(reason: "build has no APNs entitlement"),
            "VACUITY FLOOR: the failure was diagnosed before refresh.")

        await reg.refresh()

        XCTAssertEqual(reg.state, .registrationFailed(reason: "build has no APNs entitlement"))
    }

    // MARK: - Request gating

    /// iOS silently no-ops a second `requestAuthorization` after a refusal.
    /// A button that calls it from `denied` does nothing and reads as broken.
    func testRequestIsANoOpOnceDenied() async {
        let auth = ScriptedAuthority(status: .denied, requestResult: .authorized)
        let reg = PushRegistrar(authority: auth)
        await reg.refresh()
        XCTAssertEqual(reg.state, .denied, "VACUITY FLOOR: denied before request.")

        await reg.request()

        XCTAssertEqual(reg.state, .denied,
            "iOS will not re-prompt; a scripted authority that WOULD grant " +
            "must not be able to move this state, or the app offers an " +
            "affordance the platform ignores.")
        XCTAssertEqual(auth.registerCalls, 0)
    }

    func testDeclinedRequestLandsInDenied() async {
        let auth = ScriptedAuthority(status: .notDetermined, requestResult: .denied)
        let reg = PushRegistrar(authority: auth)

        await reg.request()

        XCTAssertEqual(reg.state, .denied)
        XCTAssertEqual(auth.registerCalls, 0,
            "asking APNs for a token the user refused is a wasted call whose " +
            "failure would then be reported as a platform fault.")
    }

    /// A dismissed sheet is not a refusal. Inventing one permanently
    /// suppresses the affordance.
    func testDismissedSheetStaysOfferable() async {
        let auth = ScriptedAuthority(status: .notDetermined, requestResult: .notDetermined)
        let reg = PushRegistrar(authority: auth)

        await reg.request()

        XCTAssertEqual(reg.state, .notDetermined)
    }

    // MARK: - Failure diagnosis

    /// The entitlement case is named distinctly because it is the exact
    /// configuration where a user taps Allow and nothing can ever arrive.
    func testApsEnvironmentErrorIsDiagnosedByName() {
        let auth = ScriptedAuthority(status: .authorized)
        let reg = PushRegistrar(authority: auth)

        reg.didFailToRegister(error: NSError(
            domain: "NSCocoaErrorDomain", code: 3000,
            userInfo: [NSLocalizedDescriptionKey:
                "no valid 'aps-environment' entitlement string found for application"]))

        XCTAssertEqual(reg.state, .registrationFailed(reason: "build has no APNs entitlement"))
        XCTAssertFalse(reg.state.isSubscribed)
    }

    /// The generic arm — proves the diagnosis above is a real discrimination
    /// and not a constant.
    func testOtherRegistrationErrorsAreNotDiagnosedAsEntitlement() {
        let auth = ScriptedAuthority(status: .authorized)
        let reg = PushRegistrar(authority: auth)

        reg.didFailToRegister(error: NSError(
            domain: "NSURLErrorDomain", code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]))

        XCTAssertEqual(reg.state, .registrationFailed(reason: "APNs registration failed"))
        XCTAssertNotEqual(reg.state, .registrationFailed(reason: "build has no APNs entitlement"),
            "VACUITY: the two failure reasons must differ, or the diagnosis " +
            "leg is satisfied by a function that returns one constant.")
    }

    // MARK: - Rendering

    /// No detail line may be empty and none may fabricate a token.
    func testNoDetailLineFabricatesAToken() {
        let states: [PushState] = [
            .notDetermined, .denied, .authorizedAwaitingToken,
            .registrationFailed(reason: "build has no APNs entitlement"),
        ]
        XCTAssertEqual(states.count, 4, "VACUITY FLOOR: the list is non-empty.")
        for s in states {
            let line = PushState.detailLine(for: s)
            XCTAssertFalse(line.isEmpty, "\(s) renders an empty detail line")
            XCTAssertFalse(line.contains("token ·"),
                "\(s) renders a token it does not have — a value with the " +
                "SHAPE of data that nothing recorded, the `t-12min` class.")
        }
        XCTAssertTrue(PushState.detailLine(for: .registered(tokenSuffix: "ABCD1234")).contains("token ·"),
            "VACUITY: the registered arm must be the one that CAN print it, " +
            "or the absence assertions above hold for a function that never does.")
    }
}
