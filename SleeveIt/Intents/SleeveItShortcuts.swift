import AppIntents
import SwiftUI

/// Bridges an intent's "open to measure" request into the running app's UI.
@MainActor
final class MeasureLaunchCoordinator: ObservableObject {
    static let shared = MeasureLaunchCoordinator()
    @Published var shouldOpenMeasure = false
}

/// "Measure a card" — opens SleeveIt straight into the camera measure flow.
struct MeasureCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Measure a Card"
    static var description = IntentDescription("Open SleeveIt and start measuring a card.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        MeasureLaunchCoordinator.shared.shouldOpenMeasure = true
        return .result()
    }
}

/// "How many sleeves do I need to buy" — answers from the shared snapshot without
/// opening the app.
struct SleevesToBuyIntent: AppIntent {
    static var title: LocalizedStringResource = "Sleeves To Buy"
    static var description = IntentDescription("Ask SleeveIt how many sleeves are on your shopping list.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = SharedStore.load()
        let dialog: IntentDialog
        if snapshot.totalSleeves == 0 {
            dialog = "Your shopping list is empty — nothing to buy."
        } else {
            let breakdown = snapshot.topLines.isEmpty ? "" : " (\(snapshot.topLines.joined(separator: ", ")))"
            dialog = "You need \(snapshot.totalSleeves) sleeves\(breakdown)."
        }
        return .result(dialog: dialog)
    }
}

/// Registers the phrases Siri and the Shortcuts app expose.
struct SleeveItShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MeasureCardIntent(),
            phrases: [
                "Measure a card with \(.applicationName)",
                "Start measuring in \(.applicationName)",
            ],
            shortTitle: "Measure a Card",
            systemImageName: "viewfinder"
        )
        AppShortcut(
            intent: SleevesToBuyIntent(),
            phrases: [
                "How many sleeves do I need in \(.applicationName)",
                "\(.applicationName) sleeves to buy",
            ],
            shortTitle: "Sleeves To Buy",
            systemImageName: "cart"
        )
    }
}
