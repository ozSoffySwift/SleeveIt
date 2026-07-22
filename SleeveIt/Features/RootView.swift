import SwiftUI
import SwiftData

struct RootView: View {
    enum Tab: Hashable {
        case search, measure, list, reference
    }

    @Environment(\.modelContext) private var context
    @AppStorage("appearance") private var appearance: AppearancePreference = .system

    @State private var selectedTab: Tab = .search
    @State private var isMeasurePresented = false
    @ObservedObject private var measureLaunch = MeasureLaunchCoordinator.shared

    var body: some View {
        TabView(selection: tabSelection) {
            SearchScreen(isMeasurePresented: $isMeasurePresented)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            // Presented as a full-screen cover rather than a tab body: the camera
            // owns the whole screen, and a tab bar over a live AR view reads as a
            // mistake. The tab item is kept so the design's four-tab bar survives.
            Color.clear
                .tabItem { Label("Measure", systemImage: "viewfinder") }
                .tag(Tab.measure)

            MyListScreen(isMeasurePresented: $isMeasurePresented, selectedTab: $selectedTab)
                .tabItem { Label("My List", systemImage: "checklist") }
                .tag(Tab.list)

            ReferenceScreen()
                .tabItem { Label("Reference", systemImage: "book") }
                .tag(Tab.reference)
        }
        .tint(Theme.accent)
        .preferredColorScheme(appearance.colorScheme)
        .fullScreenCover(isPresented: $isMeasurePresented) {
            MeasureScreen()
        }
        // The "Measure a Card" Shortcut opens the app and flips this flag.
        .onChange(of: measureLaunch.shouldOpenMeasure) { _, shouldOpen in
            if shouldOpen {
                isMeasurePresented = true
                measureLaunch.shouldOpenMeasure = false
            }
        }
    }

    /// Intercepts the Measure tab so it opens the camera instead of switching to
    /// an empty tab body, leaving the previous tab selected underneath.
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .measure {
                    isMeasurePresented = true
                } else {
                    selectedTab = newValue
                }
            }
        )
    }
}
