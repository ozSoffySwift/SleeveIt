import SwiftUI
import SwiftData

struct BGGImportScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage("bggUsername") private var savedUsername = ""
    @AppStorage("units") private var units: UnitPreference = .millimeters

    @Query(sort: \Game.title) private var games: [Game]
    @Query private var entries: [ListEntry]

    @State private var username = ""
    @State private var phase: Phase = .idle
    @State private var matched: [Game] = []
    @State private var unmatched: [BGGCollectionItem] = []

    private enum Phase: Equatable {
        case idle
        case loading
        case loaded(total: Int)
        case failed(String)
    }

    var body: some View {
        Form {
            if !BGGConfiguration.isConfigured {
                setupRequiredSection
            }

            Section {
                TextField("BGG username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await load() } }

                Button {
                    Task { await load() }
                } label: {
                    HStack {
                        Text("Fetch collection")
                        Spacer()
                        if phase == .loading { ProgressView() }
                    }
                }
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty
                          || phase == .loading
                          || !BGGConfiguration.isConfigured)
            } header: {
                Text("Your collection")
            } footer: {
                Text("SleeveIt reads the games you've marked as owned on BoardGameGeek. It never writes to your BGG account, and nothing about your SleeveIt list is sent anywhere.")
            }

            if case .failed(let message) = phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }

            if case .loaded(let total) = phase {
                resultsSummary(total: total)

                if !matched.isEmpty {
                    matchedSection
                }
                if !unmatched.isEmpty {
                    unmatchedSection
                }
            }
        }
        .navigationTitle("BoardGameGeek")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if username.isEmpty { username = savedUsername } }
    }

    // MARK: - Sections

    private var setupRequiredSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Setup required", systemImage: "wrench.and.screwdriver.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Since October 2025 BoardGameGeek requires apps to register and send an API token. Add yours to `BGGToken.plist` to enable importing.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Button("Register an app with BGG") {
                    openURL(BGGConfiguration.registrationURL)
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
    }

    private func resultsSummary(total: Int) -> some View {
        Section {
            LabeledContent("Games owned on BGG", value: "\(total)")
            LabeledContent("Recognised by SleeveIt", value: "\(matched.count)")
            if !unmatched.isEmpty {
                LabeledContent("Not in the catalog", value: "\(unmatched.count)")
            }
        }
    }

    private var matchedSection: some View {
        Section {
            ForEach(matched) { game in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title)
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(game.totalCards) sleeves")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isInList(game) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            Button("Add \(addableCount) game\(addableCount == 1 ? "" : "s") to My List") {
                importMatched()
            }
            .disabled(addableCount == 0)
        } header: {
            Text("Ready to import")
        } footer: {
            if addableCount == 0 && !matched.isEmpty {
                Text("All recognised games are already on your list.")
            }
        }
    }

    private var unmatchedSection: some View {
        Section {
            ForEach(unmatched) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 15))
                    if let year = item.year {
                        Text(String(year))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Not in the catalog")
        } footer: {
            // Honest about the limit: without card dimensions these games can't
            // produce a sleeve count, so importing them would be meaningless.
            Text("SleeveIt doesn't know the card sizes for these yet, so they can't be added. You can still measure their cards yourself.")
        }
    }

    // MARK: - Helpers

    private var addableCount: Int {
        matched.filter { !isInList($0) }.count
    }

    private func isInList(_ game: Game) -> Bool {
        entries.contains { $0.gameID == game.id }
    }

    // MARK: - Actions

    private func load() async {
        phase = .loading
        matched = []
        unmatched = []

        do {
            let items = try await BGGService().ownedCollection(username: username)
            var hits: [Game] = []
            var misses: [BGGCollectionItem] = []

            for item in items {
                if let game = GameTitleMatcher.match(item.title, in: games) {
                    if !hits.contains(where: { $0.id == game.id }) { hits.append(game) }
                } else {
                    misses.append(item)
                }
            }

            matched = hits.sorted { $0.title < $1.title }
            unmatched = misses.sorted { $0.title < $1.title }
            savedUsername = username.trimmingCharacters(in: .whitespaces)
            phase = .loaded(total: items.count)
        } catch let error as BGGError {
            phase = .failed(error.errorDescription ?? "Something went wrong.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func importMatched() {
        for game in matched where !isInList(game) {
            guard let sizeID = game.sizeIDs.first else { continue }
            context.insert(ListEntry(gameID: game.id, sizeID: sizeID))
        }
        try? context.save()
    }
}
