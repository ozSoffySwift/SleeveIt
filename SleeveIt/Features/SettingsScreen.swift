import SwiftUI
import SwiftData

struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @AppStorage("units") private var units: UnitPreference = .millimeters
    @AppStorage("appearance") private var appearance: AppearancePreference = .system
    @AppStorage("bggUsername") private var bggUsername = ""

    @ObservedObject private var quota = MeasurementQuota.shared

    @State private var isRefreshing = false
    @State private var refreshMessage: String?
    @State private var isCalibrationPresented = false
    /// Bumped on reset so the section re-reads the calibration state.
    @State private var calibrationVersion = 0

    // MARK: - Pro

    private func proBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .padding(.top, 3)
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .opacity(0.92)
    }

    /// Announcement only — there is no purchase flow yet, so the button is
    /// deliberately inert rather than leading somewhere that doesn't exist.
    private var proCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("SleeveIt Pro", systemImage: "rosette")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Text("COMING SOON")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(.white.opacity(0.22), in: Capsule())
            }

            Text("Measure a card and SleeveIt works out which game it's from — then adds every deck that game needs to your list in one tap.")
                .font(.system(size: 15))
                .opacity(0.92)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                proBullet("Identify the game from a measured card")
                proBullet("See every deck and its card count")
                proBullet("Add the whole game to your basket at once")
                proBullet("Unlimited measurements, no daily cap")
            }
            .padding(.top, 12)

            Text("Not yet available")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 16)
                .accessibilityLabel("SleeveIt Pro is not yet available")
        }
        .foregroundStyle(.white)
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 34 / 255, green: 122 / 255, blue: 61 / 255), Theme.accentDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(.white.opacity(0.1))
                        .frame(width: 120, height: 120)
                        .offset(x: 24, y: -24)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        }
        .padding(.vertical, 8)
    }

    var body: some View {
        Form {
            Section {
                proCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                // Interpolating `remaining` while unlimited printed Int.max —
                // a nineteen-digit number — so each state gets its own copy.
                if !quota.isEnforced {
                    Text("Camera measurements are unlimited during the launch period. The free plan's daily cap of \(quota.limit) starts later; typing dimensions by hand is always unlimited.")
                } else if quota.isUnlimited {
                    Text("Camera measurements are unlimited on your plan.")
                } else {
                    Text("Free plan: \(quota.remaining) of \(quota.limit) camera measurements left today. Typing dimensions by hand is always unlimited.")
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                Button {
                    isCalibrationPresented = true
                } label: {
                    HStack {
                        Label("Calibrate with a bank card", systemImage: "scope")
                        Spacer()
                        Text(ScaleCalibration.isCalibrated ? "Calibrated" : "Not yet")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }

                if ScaleCalibration.isCalibrated {
                    Button(role: .destructive) {
                        ScaleCalibration.reset()
                        calibrationVersion += 1
                    } label: {
                        Label("Reset calibration", systemImage: "arrow.uturn.backward")
                    }
                }
            } header: {
                Text("Measurement accuracy")
            } footer: {
                Text("Any credit or bank card is exactly 85.6 × 54.0 mm — scanning one measures your device's tiny scale bias and corrects every future measurement.")
            }
            .id(calibrationVersion)

            Section {
                Picker(selection: $units) {
                    ForEach(UnitPreference.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label("Units", systemImage: "ruler")
                }

                Button {
                    Task { await refreshCatalog() }
                } label: {
                    HStack {
                        Label("Update catalog", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if isRefreshing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isRefreshing)

                NavigationLink {
                    AboutScreen()
                } label: {
                    Label("About SleeveIt", systemImage: "info.circle")
                }
            } footer: {
                if let refreshMessage {
                    Text(refreshMessage)
                }
            }

            Section {
                NavigationLink {
                    BGGImportScreen()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("BoardGameGeek")
                            Text(bggUsername.isEmpty ? "Import your collection" : "Linked as \(bggUsername)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Theme.accent)
                    }
                }
            } header: {
                Text("Collection")
            } footer: {
                Text("Reads the games you own on BoardGameGeek. One-way — SleeveIt never changes your BGG account.")
            }

            Section {
                Text("SleeveIt 1.0 · Sleeve it, don't leave it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(isPresented: $isCalibrationPresented) {
            CalibrationScreen()
                .onDisappear { calibrationVersion += 1 }
        }
    }

    private func refreshCatalog() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let store = CatalogStore(context: context)
        let updated = await store.refresh()
        refreshMessage = updated
            ? "Catalog updated to v\(store.installedVersion)."
            : "You're on the latest catalog (v\(store.installedVersion))."
    }
}

// MARK: - About

struct AboutScreen: View {
    private enum Link {
        static let github = URL(string: "https://github.com/ozsoffy")!
        static let linkedIn = URL(string: "https://www.linkedin.com/in/ozsoffy")!
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                    Text("SleeveIt")
                        .font(.system(size: 24, weight: .bold))
                    Text("Sleeve it, don't leave it.")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Version 1.0")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            }

            Section("Developer") {
                LabeledContent("Made by", value: "Oz Soffy")

                SafariLink(
                    title: "GitHub",
                    subtitle: "github.com/ozsoffy",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    url: Link.github
                )

                SafariLink(
                    title: "LinkedIn",
                    subtitle: "linkedin.com/in/ozsoffy",
                    systemImage: "person.crop.square",
                    url: Link.linkedIn
                )
            }

            Section("Measuring") {
                Text("SleeveIt measures cards with ARKit: the camera finds the card's outline and ARKit projects its corners onto the surface it's resting on, giving real millimetres rather than pixels.")
                Text("For best results, lay the card on a flat, plain surface in good light and hold the phone roughly parallel to it.")
            }

            Section("Card data") {
                Text("Card sizes are compiled from manufacturer specs and the board gaming community's own measurements. Sizes can vary slightly between printings — check the fit before buying in bulk.")

                SafariLink(
                    title: "SleeveYourGames.com",
                    subtitle: "Card size data used with permission",
                    systemImage: "heart.circle",
                    url: URL(string: "https://www.sleeveyourgames.com")!
                )
            }

            Section {
                Text("SleeveIt is free, with no ads and no tracking. Your list stays on your device.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A settings row that opens an external profile in the browser.
private struct SafariLink: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let url: URL

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityHint("Opens \(subtitle) in your browser")
    }
}
