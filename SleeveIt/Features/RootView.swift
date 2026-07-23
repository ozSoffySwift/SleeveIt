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

    /// One-time first-run prompt recommending calibration — accuracy is the
    /// app's whole point, and calibration is what makes it trustworthy.
    @AppStorage("hasSeenCalibrationIntro") private var hasSeenCalibrationIntro = false
    @State private var isCalibrationIntroPresented = false
    @State private var isCalibrationPresented = false

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
        .fullScreenCover(isPresented: $isCalibrationPresented) {
            CalibrationScreen()
        }
        .sheet(isPresented: $isCalibrationIntroPresented) {
            CalibrationIntroSheet(
                onCalibrate: {
                    isCalibrationIntroPresented = false
                    isCalibrationPresented = true
                },
                onSkip: { isCalibrationIntroPresented = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: measureLaunch.shouldOpenMeasure) { _, shouldOpen in
            if shouldOpen {
                isMeasurePresented = true
                measureLaunch.shouldOpenMeasure = false
            }
        }
        .task {
            // Wait out the splash (3.6s hold + 0.55s fade) so the sheet rises
            // over the settled home screen, not over the branding.
            try? await Task.sleep(for: .seconds(4.4))
            guard !hasSeenCalibrationIntro, !ScaleCalibration.isCalibrated,
                  !isMeasurePresented
            else { return }
            hasSeenCalibrationIntro = true
            isCalibrationIntroPresented = true
        }
    }
}

/// First-run recommendation to calibrate — same copy as the Settings section,
/// shown once so accuracy starts trustworthy rather than discovered later.
private struct CalibrationIntroSheet: View {
    let onCalibrate: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "scope")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 30)

            Text("Get accurate measurements")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Any credit or bank card is exactly 85.6 × 54.0 mm — scanning one measures your device's tiny scale bias and corrects every future measurement.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    onCalibrate()
                } label: {
                    Label("Calibrate with a bank card", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentFill)
                .controlSize(.large)

                Button("Maybe later", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .presentationBackground(Theme.background)
    }
}
