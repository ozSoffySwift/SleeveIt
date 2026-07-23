import SwiftUI
import SwiftData

struct GameDetailScreen: View {
    let game: Game

    @Environment(\.modelContext) private var context
    @AppStorage("units") private var units: UnitPreference = .millimeters
    @Query(sort: \SleeveSize.sortIndex) private var sizes: [SleeveSize]
    @Query(sort: \Game.year) private var allGames: [Game]
    @Query private var entries: [ListEntry]

    /// Expansions the user has ticked to fold into the total. Loaded from the
    /// list entry if this game is already listed, otherwise held until Add.
    @State private var selectedExpansions: Set<String> = []
    @State private var isCorrectionPresented = false

    private var isInList: Bool {
        entries.contains { $0.gameID == game.id }
    }

    private var listedEntry: ListEntry? {
        entries.first { $0.gameID == game.id }
    }

    /// Published expansions of this game.
    private var expansions: [Game] {
        allGames.filter { $0.baseGameID == game.id }
    }

    private func size(_ id: String) -> SleeveSize? {
        sizes.first { $0.id == id }
    }

    private func gameByID(_ id: String) -> Game? {
        allGames.first { $0.id == id }
    }

    /// Base counts plus every ticked expansion.
    private var combinedCounts: [String: Int] {
        SleeveMath.combinedCounts(
            base: game,
            expansions: selectedExpansions.compactMap(gameByID)
        )
    }

    private var combinedTotal: Int {
        combinedCounts.values.reduce(0, +)
    }

    /// "170 Standard + 26 Mini", reflecting the current expansion selection.
    private var breakdown: String {
        combinedCounts
            .sorted { $0.value > $1.value }
            .compactMap { sizeID, count in
                guard let size = size(sizeID) else { return nil }
                return "\(count) \(size.shortName)"
            }
            .joined(separator: " + ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                Text("Cards to sleeve")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.3)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 24)
                    .padding(.bottom, 10)

                deckList

                if !expansions.isEmpty {
                    expansionsSection
                }

                InfoNote {
                    Text("Total: ")
                    + Text("\(combinedTotal) sleeves").fontWeight(.semibold).foregroundColor(.primary)
                    + Text(" — \(breakdown).")
                }
                .padding(.top, 14)

                Button {
                    isCorrectionPresented = true
                } label: {
                    Label("Suggest a correction", systemImage: "exclamationmark.bubble")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .background(Theme.background)
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            addButton
        }
        .task {
            recordLookup()
        }
        .onAppear {
            // Reflect what's already saved so re-opening a listed game shows the
            // expansions the user previously folded in.
            selectedExpansions = Set(listedEntry?.includedExpansionIDs ?? [])
        }
        .sheet(isPresented: $isCorrectionPresented) {
            CorrectionScreen(mode: .fixGame(id: game.id, title: game.title))
        }
    }

    private var expansionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Expansions")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.3)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 24)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(expansions.enumerated()), id: \.element.id) { index, expansion in
                    Button {
                        toggleExpansion(expansion.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedExpansions.contains(expansion.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(selectedExpansions.contains(expansion.id)
                                                 ? Theme.accent : Color.secondary.opacity(0.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expansion.title.replacingOccurrences(of: "\(game.title): ", with: ""))
                                    .font(.system(size: 16, weight: .semibold))
                                Text("+\(expansion.totalCards) sleeves")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if index < expansions.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            CoverPlaceholder(width: 78, height: 104, cornerRadius: 12)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                Text("\(game.publisher) · \(String(game.year))")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                Text("\(game.sizeIDs.count) card type\(game.sizeIDs.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var deckList: some View {
        VStack(spacing: 0) {
            ForEach(Array(game.orderedDecks.enumerated()), id: \.element.persistentModelID) { index, deck in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deck.label)
                            .font(.system(size: 17, weight: .semibold))
                        if let size = size(deck.sizeID) {
                            Text("\(deck.count) cards · \(size.long(units))")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if let size = size(deck.sizeID) {
                        SizeBadge(size: size, units: units)
                    }
                }
                .padding(16)

                if index < game.orderedDecks.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var addButton: some View {
        Button {
            addToList()
        } label: {
            Label(isInList ? "In My Sleeves" : "Add to My Sleeves",
                  systemImage: isInList ? "checkmark" : "plus")
        }
        .buttonStyle(PrimaryButtonStyle(isEnabled: !isInList))
        .disabled(isInList)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(.bar)
    }

    // MARK: - Actions

    /// Toggles an expansion. If the game is already listed, the change is saved
    /// live so the shopping list updates immediately; otherwise it's held until
    /// the user taps Add.
    private func toggleExpansion(_ id: String) {
        if selectedExpansions.contains(id) {
            selectedExpansions.remove(id)
        } else {
            selectedExpansions.insert(id)
        }
        if let entry = listedEntry {
            entry.includedExpansionIDs = Array(selectedExpansions)
            try? context.save()
        }
    }

    private func addToList() {
        guard !isInList, let firstSize = game.sizeIDs.first else { return }
        context.insert(ListEntry(
            gameID: game.id,
            sizeID: firstSize,
            includedExpansionIDs: Array(selectedExpansions)
        ))
        try? context.save()
    }

    private func recordLookup() {
        let id = game.id
        let descriptor = FetchDescriptor<RecentLookup>(predicate: #Predicate { $0.gameID == id })
        if let existing = try? context.fetch(descriptor).first {
            existing.viewedAt = .now
        } else {
            context.insert(RecentLookup(gameID: id))
        }
        try? context.save()
    }
}
