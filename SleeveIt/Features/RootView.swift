import SwiftUI
import SwiftData

struct RootView: View {
    enum Tab: Hashable {
        case search, list, reference
    }

    @Environment(\.modelContext) private var context
    @AppStorage("appearance") private var appearance: AppearancePreference = .system

    @State private var selectedTab: Tab = .search
    @State private var isMeasurePresented = false
    @ObservedObject private var measureLaunch = MeasureLaunchCoordinator.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            SearchScreen(isMeasurePresented: $isMeasurePresented)
                .tabItem { Label("Measure", systemImage: "viewfinder") }
                .tag(Tab.search)

            MyListScreen(isMeasurePresented: $isMeasurePresented, selectedTab: $selectedTab)
                .tabItem { Label("My List", systemImage: "checklist") }
                .tag(Tab.list)

            ReferenceScreen()
                .tabItem { Label("Reference", systemImage: "book") }
                .tag(Tab.reference)
        }
        .tint(Theme.accent)
        .preferredColorScheme(appearance.colorScheme)
        // The camera is a full-screen cover launched from the Measure CTA, the
        // My List buttons, and the "Measure a Card" Shortcut — not its own tab.
        .fullScreenCover(isPresented: $isMeasurePresented) {
            MeasureScreen()
        }
        .onChange(of: measureLaunch.shouldOpenMeasure) { _, shouldOpen in
            if shouldOpen {
                isMeasurePresented = true
                measureLaunch.shouldOpenMeasure = false
            }
        }
    }
}
