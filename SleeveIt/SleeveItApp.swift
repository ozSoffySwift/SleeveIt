import SwiftUI
import SwiftData

@main
struct SleeveItApp: App {
    let container: ModelContainer

    init() {
        // Firebase Analytics, configured before anything logs. Disclosed in the
        // App Store listing and privacy policy.
        AppAnalytics.configure()
        do {
            // Local-only for v1. iCloud sync of user data is planned for a
            // future version — see the README; the models are the thing that
            // changes when it lands (CloudKit forbids unique constraints and
            // needs property defaults), so it's deliberately a v2 decision.
            container = try ModelContainer(
                for: SleeveSize.self, Game.self, CardDeck.self,
                ListEntry.self, RecentLookup.self, LearnedCardPrint.self,
                SleeveStock.self
            )
        } catch {
            fatalError("Could not create the SleeveIt data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .task {
                    AppAnalytics.log(.appOpened)
                    let store = CatalogStore(context: container.mainContext)
                    store.seedIfNeeded()
                    // One-time backfill: give pre-v1.1 sleeved rows their new
                    // 3-state status (owned == fully sleeved).
                    SleeveStatusMigration.backfill(in: container.mainContext)
                    // Non-blocking: the bundled catalog is already usable, so a
                    // slow or absent network never delays first paint.
                    await store.refresh()
                }
        }
        .modelContainer(container)
    }
}
