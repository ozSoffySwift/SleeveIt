#if canImport(FirebaseAnalytics)
import FirebaseCore
import FirebaseAnalytics

/// Firebase-backed analytics. This is the only file in the app that imports
/// Firebase symbols, so the dependency stays contained behind `AnalyticsBackend`.
struct FirebaseAnalyticsBackend: AnalyticsBackend {
    func configure() {
        // Guard against double-configure (e.g. previews or repeated init).
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    func log(_ event: AnalyticsEvent) {
        Analytics.logEvent(event.name, parameters: event.parameters)
    }
}
#endif
