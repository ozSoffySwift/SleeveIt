import Foundation

/// A single analytics event. Kept as a closed enum so every logged event is
/// named in one place and the rest of the app never touches the analytics
/// backend directly.
enum AnalyticsEvent {
    case appOpened
    case cardMeasured(sizeID: String)
    case sleeveAdded(sizeID: String)
    case gameAdded(source: String)          // "catalog" | "custom"
    case calibrationCompleted
    case sleeveStatusChanged(status: String)
    case stockUpdated(sizeID: String)
    case shoppingListShared(format: String)  // "text" | "pdf"
    case reviewRequested
    case screenViewed(name: String)

    /// Firebase event name (snake_case, ≤40 chars, letters/digits/underscore).
    var name: String {
        switch self {
        case .appOpened: return "app_opened"
        case .cardMeasured: return "card_measured"
        case .sleeveAdded: return "sleeve_added"
        case .gameAdded: return "game_added"
        case .calibrationCompleted: return "calibration_completed"
        case .sleeveStatusChanged: return "sleeve_status_changed"
        case .stockUpdated: return "stock_updated"
        case .shoppingListShared: return "shopping_list_shared"
        case .reviewRequested: return "review_requested"
        case .screenViewed: return "screen_viewed"
        }
    }

    var parameters: [String: String] {
        switch self {
        case .appOpened, .calibrationCompleted, .reviewRequested:
            return [:]
        case let .cardMeasured(sizeID), let .sleeveAdded(sizeID), let .stockUpdated(sizeID):
            return ["size_id": sizeID]
        case let .gameAdded(source):
            return ["source": source]
        case let .sleeveStatusChanged(status):
            return ["status": status]
        case let .shoppingListShared(format):
            return ["format": format]
        case let .screenViewed(name):
            return ["screen_name": name]
        }
    }
}

/// The seam every feature logs through. A backend conforms to this; the app
/// only ever sees the protocol, so swapping or disabling analytics touches one
/// file, never the call sites.
protocol AnalyticsBackend {
    func configure()
    func log(_ event: AnalyticsEvent)
}

/// App-wide analytics entry point. (Named `AppAnalytics` to avoid colliding
/// with Firebase's own `Analytics` type.)
///
/// v1.1 ships Firebase Analytics, always on — the App Store listing and privacy
/// policy disclose this. The single `backend` binding is the only place that
/// knows which implementation is live.
enum AppAnalytics {
    #if canImport(FirebaseAnalytics)
    private static let backend: AnalyticsBackend = FirebaseAnalyticsBackend()
    #else
    private static let backend: AnalyticsBackend = NoopAnalyticsBackend()
    #endif

    static func configure() { backend.configure() }
    static func log(_ event: AnalyticsEvent) { backend.log(event) }
}

/// Used until the Firebase SDK is linked (and in test/preview builds), so the
/// app always compiles and runs with or without the analytics package present.
struct NoopAnalyticsBackend: AnalyticsBackend {
    func configure() {}
    func log(_ event: AnalyticsEvent) {}
}
