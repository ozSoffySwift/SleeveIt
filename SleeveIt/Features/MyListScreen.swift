import SwiftUI
import SwiftData
import WidgetKit

struct MyListScreen: View {
    @Environment(\.modelContext) private var context
    @AppStorage("units") private var units: UnitPreference = .millimeters

    @Query(sort: \ListEntry.addedAt) private var entries: [ListEntry]
    @Query(sort: \Game.title) private var games: [Game]
    @Query(sort: \SleeveSize.sortIndex) private var sizes: [SleeveSize]
    @Query private var stocks: [SleeveStock]

    /// The size whose stock is being edited, driving the editor sheet.
    @State private var stockTarget: SleeveSize?

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
            // A custom game carries its own card count; a bare measured card is 1.
            return [entry.sizeID: entry.cardCount ?? 1]
        }
        return SleeveMath.combinedCounts(
            base: game,
            expansions: entry.includedExpansionIDs.compactMap { gamesByID[$0] }
        )
    }

    /// One shopping line: what the games need, what the drawer already holds,
    /// and the difference that actually goes on the shopping trip.
    struct ShoppingLine {
        var size: SleeveSize
        var needed: Int
        var owned: Int
        var buy: Int { SleeveMath.netToBuy(needed: needed, owned: owned) }
    }

    private var shoppingList: [ShoppingLine] {
        var totals: [String: Int] = [:]

        for entry in entries where !entry.isOwned {
            for (sizeID, count) in combinedCounts(for: entry) {
                totals[sizeID, default: 0] += count
            }
        }

        let ownedBySize = Dictionary(
            uniqueKeysWithValues: stocks.map { ($0.sizeID, $0.ownedCount) })
        return totals
            .compactMap { id, needed in
                sizes.first { $0.id == id }.map {
                    ShoppingLine(size: $0, needed: needed, owned: ownedBySize[id] ?? 0)
                }
            }
            .sorted { ($0.buy, $0.needed) > ($1.buy, $1.needed) }
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
            .navigationTitle("My Sleeves")
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
    /// are listed, their sleeved state, folded-in expansions, and sleeve stock.
    private var snapshotFingerprint: String {
        let entryPart = entries
            .map { "\($0.gameID ?? $0.customTitle ?? $0.sizeID):\($0.isOwned):\($0.includedExpansionIDs.sorted().joined(separator: ","))" }
            .joined(separator: "|")
        let stockPart = stocks
            .map { "\($0.sizeID)=\($0.ownedCount)" }
            .sorted()
            .joined(separator: "|")
        return entryPart + "#" + stockPart
    }

    private func publishSnapshot() {
        // The widget answers "what do I still need to buy?" — so stock-covered
        // sizes don't count.
        let list = shoppingList.filter { $0.buy > 0 }
        SharedStore.save(SharedSnapshot(
            totalSleeves: list.reduce(0) { $0 + $1.buy },
            topLines: list.prefix(3).map { "\($0.buy)× \($0.size.shortName)" },
            gamesToSleeve: entries.filter { !$0.isOwned }.count,
            updatedAt: .now
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Export lines derived from the consolidated shopping list — net of
    /// stock, because the export is the thing taken to the shop.
    private var exportLines: [ShoppingListExport.Line] {
        shoppingList.filter { $0.buy > 0 }.map {
            ShoppingListExport.Line(
                count: $0.buy,
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
                Section {
                    ForEach(shoppingList, id: \.size.id) { line in
                        ShoppingRow(line: line, units: units) {
                            stockTarget = line.size
                        }
                    }
                } header: {
                    Text("Shopping list")
                } footer: {
                    Text("Tap a row to record how many sleeves of that size you already own — the list shows what's left to buy.")
                }

                supplyComingSoon
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
        .sheet(item: $stockTarget) { size in
            StockEditorSheet(
                size: size,
                units: units,
                needed: shoppingList.first { $0.size.id == size.id }?.needed ?? 0,
                initialOwned: stocks.first { $0.sizeID == size.id }?.ownedCount ?? 0,
                onSave: { owned in setStock(sizeID: size.id, owned: owned) }
            )
            .presentationDetents([.height(380)])
            .presentationDragIndicator(.visible)
        }
    }

    /// The future supply channel, announced where it will live: right under
    /// the list of sleeves the user needs.
    private var supplyComingSoon: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Get sleeves delivered")
                            .font(.system(size: 15, weight: .semibold))
                        Text("COMING SOON")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    Text("Order exactly these sleeves from SleeveIt, in one tap.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private func setStock(sizeID: String, owned: Int) {
        if let existing = stocks.first(where: { $0.sizeID == sizeID }) {
            existing.ownedCount = max(0, owned)
        } else {
            context.insert(SleeveStock(sizeID: sizeID, ownedCount: max(0, owned)))
        }
        try? context.save()
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
        if let custom = entry.customTitle { return custom }
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
    let line: MyListScreen.ShoppingLine
    let units: UnitPreference
    /// Row tap opens the stock editor — managing stock is the row's main job.
    let onEditStock: () -> Void
    @State private var didCopy = false

    private var isCovered: Bool { line.buy == 0 }

    private var subtitle: String {
        if line.owned > 0 {
            return "\(line.needed) needed · \(line.owned) in stock"
        }
        return line.size.long(units)
    }

    var body: some View {
        Button(action: onEditStock) {
            HStack(spacing: 10) {
                if isCovered {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.good)
                } else {
                    Text("\(line.buy)×")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(line.size.shortName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(isCovered ? "In stock — nothing to buy" : subtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if !isCovered {
                    // Copy stays one tap away for pasting into a shop's search.
                    Button {
                        UIPasteboard.general.string =
                            "\(line.buy)× \(line.size.name) sleeves (\(line.size.long(units)))"
                        withAnimation { didCopy = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation { didCopy = false }
                        }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(didCopy ? Theme.good : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// Records how many sleeves of one size the user owns. The shopping list
/// subtracts this from what the games need.
private struct StockEditorSheet: View {
    let size: SleeveSize
    let units: UnitPreference
    let needed: Int
    let initialOwned: Int
    let onSave: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ownedText = ""

    private var owned: Int { max(0, Int(ownedText) ?? 0) }
    private var remaining: Int { SleeveMath.netToBuy(needed: needed, owned: owned) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Sleeves I own") {
                        TextField("0", text: $ownedText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .frame(width: 90)
                    }

                    // One tap per pack size — stock usually arrives in packs.
                    HStack(spacing: 8) {
                        ForEach([50, 100], id: \.self) { pack in
                            Button("+\(pack)") { ownedText = String(owned + pack) }
                                .buttonStyle(.bordered)
                                .tint(Theme.accent)
                        }
                        Spacer()
                        Button("Clear", role: .destructive) { ownedText = "0" }
                            .buttonStyle(.bordered)
                    }
                    .font(.system(size: 14, weight: .semibold))
                } footer: {
                    Text(remaining == 0
                        ? "Your stock covers everything — nothing to buy in this size."
                        : "Games need \(needed) · you own \(owned) → buy \(remaining).")
                }
            }
            .navigationTitle(size.shortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(owned)
                        dismiss()
                    }
                }
            }
            .onAppear { ownedText = String(initialOwned) }
        }
    }
}
