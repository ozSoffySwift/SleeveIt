import XCTest
@testable import SleeveIt

@MainActor
final class MeasurementQuotaTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "quota.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A clock safely after `enforcementStart`, so cap tests exercise the
    /// enforced behaviour regardless of when they run.
    private let enforcedClock: () -> Date = {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
    }

    /// A clock just before enforcement begins.
    private let freeWindowClock: () -> Date = {
        Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 31, hour: 23))!
    }

    private func enforcedQuota(entitlements: Entitlements? = nil) -> MeasurementQuota {
        MeasurementQuota(
            defaults: defaults,
            entitlements: entitlements ?? Entitlements(isPro: false),
            now: enforcedClock
        )
    }

    // MARK: - Dated enforcement window

    func testBeforeAugustFirstTheCapIsNotEnforced() {
        let quota = MeasurementQuota(
            defaults: defaults, entitlements: Entitlements(isPro: false), now: freeWindowClock)

        for _ in 0..<50 { quota.recordMeasurement() }

        XCTAssertFalse(quota.isEnforced)
        XCTAssertTrue(quota.isUnlimited)
        XCTAssertTrue(quota.canMeasure)
        XCTAssertEqual(quota.usedToday, 0, "The free window must not accrue usage")
    }

    func testFromAugustFirstTheCapIsEnforced() {
        let augustFirst: () -> Date = {
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 0, minute: 1))!
        }
        let quota = MeasurementQuota(
            defaults: defaults, entitlements: Entitlements(isPro: false), now: augustFirst)

        XCTAssertTrue(quota.isEnforced)
        XCTAssertFalse(quota.isUnlimited)
        for _ in 0..<MeasurementQuota.freeDailyLimit { quota.recordMeasurement() }
        XCTAssertFalse(quota.canMeasure)
    }

    func testFreeTierStartsWithTheFullDailyAllowance() {
        let quota = enforcedQuota()
        XCTAssertEqual(quota.remaining, MeasurementQuota.freeDailyLimit)
        XCTAssertTrue(quota.canMeasure)
    }

    func testEachMeasurementConsumesOneAndTheLimitBlocks() {
        let quota = enforcedQuota()

        for step in 1...MeasurementQuota.freeDailyLimit {
            XCTAssertTrue(quota.canMeasure, "Should still allow measurement \(step)")
            quota.recordMeasurement()
        }

        XCTAssertEqual(quota.remaining, 0)
        XCTAssertFalse(quota.canMeasure)
    }

    func testUsageBeyondTheLimitCannotDriveRemainingNegative() {
        let quota = enforcedQuota()
        for _ in 0..<(MeasurementQuota.freeDailyLimit + 4) {
            quota.recordMeasurement()
        }
        XCTAssertEqual(quota.remaining, 0)
    }

    func testUsageSurvivesRelaunchWithinTheSameDay() {
        let first = enforcedQuota()
        first.recordMeasurement()
        first.recordMeasurement()

        // A fresh instance models the app being relaunched.
        let second = enforcedQuota()
        XCTAssertEqual(second.usedToday, 2)
        XCTAssertEqual(second.remaining, MeasurementQuota.freeDailyLimit - 2)
    }

    func testAllowanceResetsOnANewDay() {
        let quota = enforcedQuota()
        for _ in 0..<MeasurementQuota.freeDailyLimit { quota.recordMeasurement() }
        XCTAssertFalse(quota.canMeasure)

        // Backdate the stored day to simulate crossing midnight.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: enforcedClock())!
        defaults.set(Calendar.current.startOfDay(for: yesterday), forKey: "quota.dayStart")

        let tomorrow = enforcedQuota()
        XCTAssertEqual(tomorrow.usedToday, 0)
        XCTAssertTrue(tomorrow.canMeasure)
        XCTAssertEqual(tomorrow.remaining, MeasurementQuota.freeDailyLimit)
    }

    func testRolloverIsDetectedWithoutRelaunching() {
        let quota = enforcedQuota()
        quota.recordMeasurement()

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: enforcedClock())!
        defaults.set(Calendar.current.startOfDay(for: yesterday), forKey: "quota.dayStart")

        // The app may sit backgrounded across midnight, so a live instance must
        // notice the new day too.
        quota.rolloverIfNeeded()
        XCTAssertEqual(quota.usedToday, 0)
    }

    func testUnlimitedIgnoresTheCapEntirely() {
        let quota = enforcedQuota(entitlements: Entitlements(isPro: true))

        for _ in 0..<50 { quota.recordMeasurement() }

        XCTAssertTrue(quota.canMeasure)
        XCTAssertEqual(quota.usedToday, 0, "Unlimited use should not accrue against the free counter")
    }

    func testResetsAtIsTheStartOfTomorrow() {
        let quota = enforcedQuota()
        let calendar = Calendar.current
        XCTAssertTrue(calendar.isDate(
            quota.resetsAt,
            inSameDayAs: calendar.date(byAdding: .day, value: 1, to: enforcedClock())!
        ))
        XCTAssertEqual(calendar.component(.hour, from: quota.resetsAt), 0)
        XCTAssertGreaterThan(quota.resetsAt, enforcedClock())
    }
}
