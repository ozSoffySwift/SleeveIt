import Foundation

/// A tiny snapshot of the shopping list, shared with the widget and read by
/// Shortcuts.
///
/// Deliberately NOT a shared SwiftData store: the widget only needs a handful of
/// numbers, and a couple of `UserDefaults` values in the App Group are far more
/// robust than mirroring the whole store into an extension. The app writes this
/// on every My List change; the widget and intents read it.
struct SharedSnapshot: Codable, Equatable {
    var totalSleeves: Int
    var topLines: [String]   // e.g. ["892× Standard", "31× Mini"]
    var gamesToSleeve: Int
    var updatedAt: Date

    static let empty = SharedSnapshot(totalSleeves: 0, topLines: [], gamesToSleeve: 0, updatedAt: .distantPast)
}

enum SharedStore {
    /// The App Group both the app and the widget share. Configured in each
    /// target's entitlements; falls back to standard defaults if the group isn't
    /// available (e.g. before the capability is provisioned), so nothing crashes.
    static let appGroupID = "group.com.ozsoffy.SleeveIt"

    private static let key = "sharedSnapshot"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func save(_ snapshot: SharedSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> SharedSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(SharedSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}
