import XCTest
@testable import Zeus

/// Cold-start restore.
///
/// The defect these guard is not a crash and not a wrong value on screen: it
/// is the app *forgetting* a completed commissioning across a process
/// boundary, which produces a correct-looking splash screen and no error at
/// all. Nothing in the type system objects to `@State` losing its value —
/// that is what `@State` is for — so the only instrument that can see this is
/// a test that constructs a **second** `AppState` over the same store.
@MainActor
final class CommissionStoreTests: XCTestCase {

    /// A `UserDefaults` suite unique to each test, removed on teardown.
    ///
    /// Not `.standard`: a test writing there mutates the simulator's real
    /// preference domain, survives the process, and leaks into every later
    /// test — the same reasoning that keeps `GatewayConfig.resolve(from:)`
    /// taking its environment as a parameter rather than reading `ProcessInfo`.
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.zeus.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> UserDefaultsCommissionStore {
        UserDefaultsCommissionStore(defaults: defaults)
    }

    // MARK: - Round trip

    /// VACUITY FLOOR for every test below: an untouched store reads `nil`.
    ///
    /// Without this, a store that returned `nil` unconditionally would pass
    /// the "clear" test and fail nothing — and a store that returned a
    /// default `Commission()` would make the restore assertions look like
    /// they were reading a real record when they were reading a constant.
    func testEmptyStoreLoadsNil() {
        XCTAssertNil(makeStore().load())
    }

    func testSaveThenLoadRoundTripsEveryField() {
        let store = makeStore()
        let written = Commission(route: .byok, callsign: "MIGUEL", nodeEnrolled: true)
        store.save(written)

        let read = store.load()
        XCTAssertEqual(read, written)
        // Field-wise as well as whole-value: `Equatable` on a struct with a
        // field the encoder silently dropped would still compare equal if the
        // decoder defaulted it the same way on both sides.
        XCTAssertEqual(read?.route, .byok)
        XCTAssertEqual(read?.callsign, "MIGUEL")
        XCTAssertEqual(read?.nodeEnrolled, true)
    }

    /// The two non-default field values are asserted to actually DIFFER from
    /// a fresh `Commission()`, so the round-trip above cannot be satisfied by
    /// a decoder that ignores the payload and returns defaults.
    func testRoundTripFixtureDiffersFromDefault() {
        let fresh = Commission()
        let written = Commission(route: .byok, callsign: "MIGUEL", nodeEnrolled: true)
        XCTAssertNotEqual(fresh, written)
        XCTAssertNotEqual(fresh.route, written.route)
        XCTAssertNotEqual(fresh.nodeEnrolled, written.nodeEnrolled)
    }

    func testSaveOverwritesPreviousValue() {
        let store = makeStore()
        store.save(Commission(route: .managed, callsign: "FIRST", nodeEnrolled: false))
        store.save(Commission(route: .byok, callsign: "SECOND", nodeEnrolled: true))
        XCTAssertEqual(store.load()?.callsign, "SECOND")
    }

    func testClearForgets() {
        let store = makeStore()
        store.save(Commission(route: .managed, callsign: "X", nodeEnrolled: false))
        XCTAssertNotNil(store.load(), "vacuity floor: there was something to clear")
        store.clear()
        XCTAssertNil(store.load())
    }

    /// A corrupted blob reads as "no commission" and is removed — not a
    /// crash, and not a default-constructed value that would silently skip
    /// commissioning for an operator who never did it.
    func testCorruptPayloadLoadsNilAndSelfHeals() {
        defaults.set(Data("not json".utf8), forKey: UserDefaultsCommissionStore.key)
        let store = makeStore()
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: UserDefaultsCommissionStore.key),
                     "the undecodable record is removed rather than re-read every launch")
    }

    // MARK: - Cold start, across two AppState instances

    /// THE POINT OF THE FILE.
    ///
    /// Two `AppState` instances over one store stands in for two app
    /// lifetimes. A single instance would pass trivially — it would be
    /// reading the field it just wrote — which is exactly the shape the
    /// `@State` version had and exactly why it went unnoticed.
    func testCommissionSurvivesIntoAFreshAppState() {
        let store = makeStore()

        let first = AppState(store: store)
        XCTAssertNil(first.commission, "vacuity floor: launch one is uncommissioned")
        first.commission(Commission(route: .byok, callsign: "MIGUEL", nodeEnrolled: true))
        XCTAssertNotNil(first.commission)

        let second = AppState(store: store)
        XCTAssertEqual(second.commission?.callsign, "MIGUEL")
        XCTAssertEqual(second.commission?.route, .byok)
        XCTAssertEqual(second.commission?.nodeEnrolled, true)
    }

    /// The negative arm, and it is not redundant with the floor above: it
    /// proves a *decommission* also crosses the boundary. A store that only
    /// ever appended would pass the restore test and fail this one.
    func testDecommissionSurvivesIntoAFreshAppState() {
        let store = makeStore()

        let first = AppState(store: store)
        first.commission(Commission(route: .managed, callsign: "MIGUEL", nodeEnrolled: false))
        XCTAssertNotNil(AppState(store: store).commission,
                        "vacuity floor: it was restorable before the revoke")

        first.decommission()
        XCTAssertNil(first.commission)
        XCTAssertNil(AppState(store: store).commission)
    }

    /// Persist-before-publish: the store holds the value at the instant the
    /// published property changes, so a crash in the same turn as the
    /// transition cannot strand the operator on a console that will be gone.
    func testCommissionWritesStoreBeforePublishing() {
        let store = makeStore()
        let state = AppState(store: store)
        state.commission(Commission(route: .managed, callsign: "ORDER", nodeEnrolled: false))
        XCTAssertEqual(store.load()?.callsign, "ORDER")
        XCTAssertEqual(state.commission?.callsign, "ORDER")
    }

    // MARK: - In-memory store

    func testInMemoryStoreSeedsAndClears() {
        let seeded = InMemoryCommissionStore(seed: Commission(route: .byok, callsign: "S", nodeEnrolled: true))
        XCTAssertEqual(seeded.load()?.callsign, "S")
        seeded.clear()
        XCTAssertNil(seeded.load())
    }

    /// The in-memory store must NOT reach `UserDefaults` — a screenshot run
    /// seeding a commission cannot be allowed to change what a later
    /// unargumented launch photographs.
    func testInMemoryStoreDoesNotTouchUserDefaults() {
        let memory = InMemoryCommissionStore()
        memory.save(Commission(route: .byok, callsign: "GHOST", nodeEnrolled: true))
        XCTAssertNil(defaults.data(forKey: UserDefaultsCommissionStore.key))
        XCTAssertNil(UserDefaults.standard.data(forKey: UserDefaultsCommissionStore.key),
                     "and not the standard domain either")
    }
}
