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

    func testFreeTierStartsWithTheFullDailyAllowance() {
        let quota = MeasurementQuota(defaults: defaults)
        XCTAssertEqual(quota.remaining, MeasurementQuota.freeDailyLimit)
        XCTAssertTrue(quota.canMeasure)
    }

    func testEachMeasurementConsumesOneAndTheLimitBlocks() {
        let quota = MeasurementQuota(defaults: defaults)

        for step in 1...MeasurementQuota.freeDailyLimit {
            XCTAssertTrue(quota.canMeasure, "Should still allow measurement \(step)")
            quota.recordMeasurement()
        }

        XCTAssertEqual(quota.remaining, 0)
        XCTAssertFalse(quota.canMeasure)
    }

    func testUsageBeyondTheLimitCannotDriveRemainingNegative() {
        let quota = MeasurementQuota(defaults: defaults)
        for _ in 0..<(MeasurementQuota.freeDailyLimit + 4) {
            quota.recordMeasurement()
        }
        XCTAssertEqual(quota.remaining, 0)
    }

    func testUsageSurvivesRelaunchWithinTheSameDay() {
        let first = MeasurementQuota(defaults: defaults)
        first.recordMeasurement()
        first.recordMeasurement()

        // A fresh instance models the app being relaunched.
        let second = MeasurementQuota(defaults: defaults)
        XCTAssertEqual(second.usedToday, 2)
        XCTAssertEqual(second.remaining, MeasurementQuota.freeDailyLimit - 2)
    }

    func testAllowanceResetsOnANewDay() {
        let quota = MeasurementQuota(defaults: defaults)
        for _ in 0..<MeasurementQuota.freeDailyLimit { quota.recordMeasurement() }
        XCTAssertFalse(quota.canMeasure)

        // Backdate the stored day to simulate crossing midnight.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        defaults.set(Calendar.current.startOfDay(for: yesterday), forKey: "quota.dayStart")

        let tomorrow = MeasurementQuota(defaults: defaults)
        XCTAssertEqual(tomorrow.usedToday, 0)
        XCTAssertTrue(tomorrow.canMeasure)
        XCTAssertEqual(tomorrow.remaining, MeasurementQuota.freeDailyLimit)
    }

    func testRolloverIsDetectedWithoutRelaunching() {
        let quota = MeasurementQuota(defaults: defaults)
        quota.recordMeasurement()

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        defaults.set(Calendar.current.startOfDay(for: yesterday), forKey: "quota.dayStart")

        // The app may sit backgrounded across midnight, so a live instance must
        // notice the new day too.
        quota.rolloverIfNeeded()
        XCTAssertEqual(quota.usedToday, 0)
    }

    func testUnlimitedIgnoresTheCapEntirely() {
        let pro = Entitlements(isPro: true)
        let quota = MeasurementQuota(defaults: defaults, entitlements: pro)

        for _ in 0..<50 { quota.recordMeasurement() }

        XCTAssertTrue(quota.canMeasure)
        XCTAssertEqual(quota.usedToday, 0, "Unlimited use should not accrue against the free counter")
    }

    func testResetsAtIsTheStartOfTomorrow() {
        let quota = MeasurementQuota(defaults: defaults)
        let calendar = Calendar.current
        XCTAssertTrue(calendar.isDate(
            quota.resetsAt,
            inSameDayAs: calendar.date(byAdding: .day, value: 1, to: .now)!
        ))
        XCTAssertEqual(calendar.component(.hour, from: quota.resetsAt), 0)
        XCTAssertGreaterThan(quota.resetsAt, .now)
    }
}
