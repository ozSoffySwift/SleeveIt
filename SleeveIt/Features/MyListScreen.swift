import SwiftUI
import SwiftData
import WidgetKit

struct MyListScreen: View {
    @Environment(\.modelContext) private var context
    @AppStorage("units") private var units: UnitPreference = .millimeters

    @Query(sort: \ListEntry.addedAt) private var entries: [ListEntry]
    @Query(sort: \Game.title) private var games: [Game]
    @Query(sort: \SleeveSize.sortIndex) private var sizes: [SleeveSize]

    @Binding var isMeasurePresented: Bool
    @Binding var selectedTab: RootView.Tab

    /// Sleeves still to buy, consolidated across every unowned entry.
    ///
    /// This is the screen's reason to exist: three games needing standard sleeves
    /// should read as one line of 550, not three lines the user has to add up.
    private var gamesByID: [String: Game] {
        Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
    }

    /// Cards-per-size for one entry, base game plus every expansion it folds in.
    private func combinedCounts(for entry: ListEntry) -> [String: Int] {
        guard let gameID = entry.gameID, let game = gamesByID[gameID] else {
            return [entry.sizeID: 1] // a measured card
        }
        return SleeveMath.combinedCounts(
            base: game,
            expansions: entry.includedExpansionIDs.compactMap { gamesByID[$0] }
        )
    }

    private var shoppingList: [(size: SleeveSize, count: Int)] {
        var totals: [String: Int] = [:]

        for entry in entries where !entry.isOwned {
            for (sizeID, count) in combinedCounts(for: entry) {
                totals[sizeID, default: 0] += count
            }
        }

        return totals
            .compactMap { id, count in
                sizes.first { $0.id == id }.map { (size: $0, count: count) }
            }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("My List")
            .navigationDestination(for: Game.self) { GameDetailScreen(game: $0) }
            .onAppear { publishSnapshot() }
            .onChange(of: snapshotFingerprint) { publishSnapshot() }
            .toolbar {
                if !shoppingList.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        shareMenu
                    }
                }
            }
        }
    }

    /// Changes whenever anything that affects the snapshot changes: which games
    /// are listed, their sleeved state, and their folded-in expansions.
    private var snapshotFingerprint: String {
        entries
            .map { "\($0.gameID ?? $0.sizeID):\($0.isOwned):\($0.includedExpansionIDs.sorted().joined(separator: ","))" }
            .joined(separator: "|")
    }

    private func publishSnapshot() {
        let list = shoppingList
        SharedStore.save(SharedSnapshot(
            totalSleeves: list.reduce(0) { $0 + $1.count },
            topLines: list.prefix(3).map { "\($0.count)× \($0.size.shortName)" },
            gamesToSleeve: entries.filter { !$0.isOwned }.count,
            updatedAt: .now
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Export lines derived from the consolidated shopping list.
    private var exportLines: [ShoppingListExport.Line] {
        shoppingList.map {
            ShoppingListExport.Line(
                count: $0.count,
                sizeName: $0.size.shortName,
                dimensions: $0.size.long(units)
            )
        }
    }

    @ViewBuilder
    private var shareMenu: some View {
        let text = ShoppingListExport.text(lines: exportLines)
        Menu {
            ShareLink(item: text) {
                Label("Share as text", systemImage: "text.alignleft")
            }
            if let pdf = ShoppingListExport.pdf(lines: exportLines) {
                ShareLink(item: pdf) {
                    Label("Export as PDF", systemImage: "doc.richtext")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    // MARK: - List

    /// How many list entries are marked sleeved, over the total.
    private var sleevedProgress: (done: Int, total: Int) {
        (entries.filter(\.isOwned).count, entries.count)
    }

    private var list: some View {
        List {
            Section {
                ProgressHeader(done: sleevedProgress.done, total: sleevedProgress.total)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section("Games to sleeve") {
                ForEach(entries) { entry in
                    EntryRow(
                        entry: entry,
                        game: entry.gameID.flatMap { gamesByID[$0] },
                        counts: combinedCounts(for: entry),
                        expansionCount: entry.includedExpansionIDs.count,
                        sizes: sizes,
                        units: units,
                        onToggleOwned: { toggle(entry) }
                    )
                }
                .onDelete(perform: delete)
            }

            if !shoppingList.isEmpty {
                Section("Shopping list") {
                    ForEach(shoppingList, id: \.size.id) { item in
                        ShoppingRow(size: item.size, count: item.count, units: units)
                    }
                }
            } else {
                Section {
                    InfoNote(icon: "checkmark.circle.fill") {
                        Text("Everything on your list is sleeved. Nothing to buy.")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "text.badge.plus",
            title: "Your list is empty",
            message: "Add a game from its detail page, or measure a card — SleeveIt builds your shopping list automatically."
        ) {
            VStack(spacing: 12) {
                Button("Find a game", systemImage: "magnifyingglass") {
                    selectedTab = .search
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Measure a card", systemImage: "viewfinder") {
                    isMeasurePresented = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Actions

    private func toggle(_ entry: ListEntry) {
        entry.isOwned.toggle()
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(entries[index])
        }
        try? context.save()
    }
}

// MARK: - Progress

/// "X of Y sleeved" with a bar, above the list. Turns the per-row checkmarks
/// into a collection-completion sense the app didn't surface before.
private struct ProgressHeader: View {
    let done: Int
    let total: Int

    private var fraction: Double {
        total == 0 ? 0 : Double(done) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(done == total ? "All sleeved" : "\(done) of \(total) sleeved")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if done == total, total > 0 {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.good)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule()
                        .fill(done == total ? Theme.good : Theme.accent)
                        .frame(width: max(0, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
            .animation(.snappy(duration: 0.3), value: fraction)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Rows

private struct EntryRow: View {
    let entry: ListEntry
    let game: Game?
    /// Cards-per-size for this entry, base plus folded-in expansions.
    let counts: [String: Int]
    let expansionCount: Int
    let sizes: [SleeveSize]
    let units: UnitPreference
    let onToggleOwned: () -> Void

    private var title: String {
        if let game { return game.title }
        guard let w = entry.measuredWidthMM, let h = entry.measuredHeightMM else {
            return "Measured card"
        }
        return "Measured · \(units.compact(width: w, height: h))"
    }

    /// Chips ordered by descending count, so the dominant sleeve size leads.
    private var chips: [String] {
        counts
            .sorted { $0.value > $1.value }
            .compactMap { sizeID, count in
                guard let size = sizes.first(where: { $0.id == sizeID }) else { return nil }
                return "\(count)× \(size.compact(units))"
            }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleOwned) {
                Image(systemName: entry.isOwned ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(entry.isOwned ? Theme.accent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            CoverPlaceholder(width: 36, height: 48)
                .opacity(entry.isOwned ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .strikethrough(entry.isOwned)
                        .foregroundStyle(entry.isOwned ? .secondary : .primary)
                    if expansionCount > 0 {
                        Text("+\(expansionCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                            .accessibilityLabel("\(expansionCount) expansions included")
                    }
                }

                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(entry.isOwned ? Color.secondary : Theme.accent)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(
                                (entry.isOwned ? Color.secondary.opacity(0.15) : Theme.accent.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                }
            }

            Spacer(minLength: 0)

            if entry.isOwned {
                Text("Sleeved")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .background {
            // Whole-row tap opens the game, without swallowing the checkbox.
            if let game {
                NavigationLink(value: game) { EmptyView() }.opacity(0)
            }
        }
    }
}

private struct ShoppingRow: View {
    let size: SleeveSize
    let count: Int
    let units: UnitPreference
    @State private var didCopy = false

    var body: some View {
        Button {
            UIPasteboard.general.string = "\(count)× \(size.name) sleeves (\(size.long(units)))"
            withAnimation { didCopy = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { didCopy = false }
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(count)×")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(size.shortName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(size.long(units))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(didCopy ? Theme.good : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
