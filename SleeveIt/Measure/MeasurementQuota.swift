import Foundation
import Combine

/// Tracks how many camera measurements have been taken today.
///
/// The free tier allows `freeDailyLimit` AR measurements per day. A future paid
/// tier lifts the cap entirely — `isUnlimited` is the single switch that will be
/// driven by a real entitlement once purchasing exists.
///
/// **Only AR measurements count against the quota.** Manual entry is deliberately
/// free: it exists as the fallback for when detection fails, and charging a quota
/// unit because the app couldn't see the card would punish the user for the
/// app's shortcoming.
@MainActor
final class MeasurementQuota: ObservableObject {
    static let freeDailyLimit = 5

    static let shared = MeasurementQuota()

    @Published private(set) var usedToday: Int = 0

    /// Pro lifts the cap entirely. Sourced from `Entitlements` so there is one
    /// switch for every paid capability, not one per feature.
    var isUnlimited: Bool { entitlements.isPro }

    private let entitlements: Entitlements
    private let defaults: UserDefaults
    private let calendar: Calendar

    private enum Key {
        static let count = "quota.usedToday"
        static let day = "quota.dayStart"
    }

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        entitlements: Entitlements = .shared
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.entitlements = entitlements
        rolloverIfNeeded()
    }

    var limit: Int { Self.freeDailyLimit }

    var remaining: Int {
        isUnlimited ? .max : max(0, limit - usedToday)
    }

    var canMeasure: Bool {
        isUnlimited || remaining > 0
    }

    /// When the allowance next resets, for the "come back tomorrow" copy.
    var resetsAt: Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: .now) ?? .now)
    }

    /// Records one completed AR measurement. Safe to call when unlimited — it
    /// simply doesn't count.
    func recordMeasurement() {
        rolloverIfNeeded()
        guard !isUnlimited else { return }
        usedToday += 1
        defaults.set(usedToday, forKey: Key.count)
    }

    /// Resets the counter when the calendar day has changed since it was stored.
    ///
    /// Called on every read path rather than scheduled, so the allowance is
    /// correct after the app has been backgrounded across midnight.
    func rolloverIfNeeded() {
        let today = calendar.startOfDay(for: .now)
        let storedDay = defaults.object(forKey: Key.day) as? Date

        guard let storedDay, calendar.isDate(storedDay, inSameDayAs: today) else {
            usedToday = 0
            defaults.set(0, forKey: Key.count)
            defaults.set(today, forKey: Key.day)
            return
        }
        usedToday = defaults.integer(forKey: Key.count)
    }

    #if DEBUG
    /// Test seam — lets a test place the store in a known state.
    func reset() {
        defaults.removeObject(forKey: Key.count)
        defaults.removeObject(forKey: Key.day)
        rolloverIfNeeded()
    }
    #endif
}
