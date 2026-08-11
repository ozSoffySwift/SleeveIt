import SwiftUI
import SwiftData
import WidgetKit

/// My Sleeves — the collection hub. Three tabs:
/// • **Games**  — the games you own, each with a 3-state sleeving status and notes.
/// • **Shopping** — sleeves still to buy, consolidated and net of what you stock.
/// • **Stock**   — how many sleeves of each size you own, and the brand you use.
struct MyListScreen: View {
    @Environment(\.modelContext) private var context
    @AppStorage("units") private var units: UnitPreference = .millimeters

    @Query(sort: \ListEntry.addedAt) private var entries: [ListEntry]
    @Query(sort: \Game.title) private var games: [Game]
    @Query(sort: \SleeveSize.sortIndex) private var sizes: [SleeveSize]
    @Query private var stocks: [SleeveStock]

    @Binding var isMeasurePresented: Bool
    @Binding var selectedTab: RootView.Tab

    @State private var tab: Tab = .games
    @State private var statusFilter: StatusFilter = .all
    @State private var sortOrder: SortOrder = .recent
    @State private var stockTarget: SleeveSize?
    @State private var editingEntry: ListEntry?

    enum Tab: String, CaseIterable, Identifiable {
        case games = "Games", shopping = "Shopping", stock = "Stock"
        var id: String { rawValue }
    }
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All", toSleeve = "To sleeve", inProgress = "In progress", sleeved = "Sleeved"
        var id: String { rawValue }
    }
    enum SortOrder: String, CaseIterable, Identifiable {
        case recent = "Recently added", name = "Name", cards = "Most cards"
        var id: String { rawValue }
    }

    private var gamesByID: [String: Game] {
        Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        Picker("View", selection: $tab) {
                            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        switch tab {
                        case .games: gamesTab
                        case .shopping: shoppingTab
                        case .stock: stockTab
                        }
                    }
                    .background(Theme.background)
                }
            }
            .navigationTitle("My Sleeves")
            .navigationDestination(for: Game.self) { GameDetailScreen(game: $0) }
            .onAppear { publishSnapshot() }
            .onChange(of: snapshotFingerprint) { publishSnapshot() }
            .toolbar { toolbarContent }
            .sheet(item: $stockTarget) { size in
                StockEditorSheet(
                    size: size,
                    units: units,
                    needed: shoppingList.first { $0.size.id == size.id }?.needed ?? 0,
                    stock: stocks.first { $0.sizeID == size.id },
                    onSave: { owned, brand in setStock(sizeID: size.id, owned: owned, brand: brand) }
                )
                .presentationDetents([.height(440)])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $editingEntry) { entry in
                EntryDetailSheet(
                    entry: entry,
                    game: entry.gameID.flatMap { gamesByID[$0] },
                    counts: combinedCounts(for: entry),
                    sizes: sizes,
                    units: units,
                    onDelete: { delete(entry) }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if tab == .games {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        } else if tab == .shopping, !exportLines.isEmpty {
            ToolbarItem(placement: .topBarTrailing) { shareMenu }
        }
    }

    // MARK: - Games tab

    private var visibleEntries: [ListEntry] {
        var result = entries
        switch statusFilter {
        case .all: break
        case .toSleeve: result = result.filter { $0.sleeveStatus == .notSleeved }
        case .inProgress: result = result.filter { $0.sleeveStatus == .inProgress }
        case .sleeved: result = result.filter { $0.sleeveStatus == .sleeved }
        }
        switch sortOrder {
        case .recent: result.sort { $0.addedAt > $1.addedAt }
        case .name: result.sort { title(for: $0).localizedCompare(title(for: $1)) == .orderedAscending }
        case .cards: result.sort { totalCards(for: $0) > totalCards(for: $1) }
        }
        return result
    }

    private var sleevedProgress: (done: Int, total: Int) {
        (entries.filter { $0.sleeveStatus == .sleeved }.count, entries.count)
    }

    @ViewBuilder private var gamesTab: some View {
        List {
            Section {
                ProgressHeader(done: sleevedProgress.done, total: sleevedProgress.total)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            if visibleEntries.isEmpty {
                Section {
                    InfoNote(icon: "line.3.horizontal.decrease.circle") {
                        Text("No games match this filter.")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(visibleEntries) { entry in
                        EntryRow(
                            entry: entry,
                            game: entry.gameID.flatMap { gamesByID[$0] },
                            counts: combinedCounts(for: entry),
                            expansionCount: entry.includedExpansionIDs.count,
                            sizes: sizes,
                            units: units,
                            onCycleStatus: { cycleStatus(entry) },
                            onOpen: { editingEntry = entry }
                        )
                    }
                    .onDelete { offsets in
                        offsets.map { visibleEntries[$0] }.forEach(delete)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $statusFilter) {
                ForEach(StatusFilter.allCases) { Label($0.rawValue, systemImage: filterIcon($0)).tag($0) }
            }
            Divider()
            Picker("Sort by", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: statusFilter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private func filterIcon(_ f: StatusFilter) -> String {
        switch f {
        case .all: return "square.stack.3d.up"
        case .toSleeve: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .sleeved: return "checkmark.circle.fill"
        }
    }

    // MARK: - Shopping tab

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
        for entry in entries where entry.sleeveStatus != .sleeved {
            for (sizeID, count) in combinedCounts(for: entry) {
                totals[sizeID, default: 0] += count
            }
        }
        let ownedBySize = Dictionary(uniqueKeysWithValues: stocks.map { ($0.sizeID, $0.ownedCount) })
        return totals
            .compactMap { id, needed in
                sizes.first { $0.id == id }.map {
                    ShoppingLine(size: $0, needed: needed, owned: ownedBySize[id] ?? 0)
                }
            }
            .sorted { ($0.buy, $0.needed) > ($1.buy, $1.needed) }
    }

    @ViewBuilder private var shoppingTab: some View {
        List {
            if shoppingList.isEmpty {
                Section {
                    InfoNote(icon: "checkmark.circle.fill") {
                        Text("Everything you own is sleeved. Nothing to buy.")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(shoppingList, id: \.size.id) { line in
                        ShoppingRow(line: line, units: units) { stockTarget = line.size }
                    }
                } header: {
                    Text("Sleeves to buy")
                } footer: {
                    Text("Tap a row to record how many sleeves of that size you already own — the list shows what's left to buy.")
                }

                supplyComingSoon
            }
        }
        .listStyle(.insetGrouped)
    }

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

    // MARK: - Stock tab

    /// Sizes worth managing stock for: any size a game needs, plus any the user
    /// already stocks.
    private var stockSizes: [SleeveSize] {
        let needed = Set(shoppingList.map(\.size.id))
        let owned = Set(stocks.filter { $0.ownedCount > 0 || !$0.brand.isEmpty }.map(\.sizeID))
        let ids = needed.union(owned)
        return sizes.filter { ids.contains($0.id) }
    }

    @ViewBuilder private var stockTab: some View {
        List {
            if stockSizes.isEmpty {
                Section {
                    InfoNote(icon: "tray") {
                        Text("Add games or measure cards, then record the sleeves you already own here.")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(stockSizes, id: \.id) { size in
                        StockRow(
                            size: size,
                            stock: stocks.first { $0.sizeID == size.id },
                            needed: shoppingList.first { $0.size.id == size.id }?.needed ?? 0,
                            units: units,
                            onEdit: { stockTarget = size }
                        )
                    }
                } header: {
                    Text("My sleeve stock")
                } footer: {
                    Text("Tap a size to set how many you own and which brand you buy.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Shared helpers

    private func combinedCounts(for entry: ListEntry) -> [String: Int] {
        guard let gameID = entry.gameID, let game = gamesByID[gameID] else {
            return [entry.sizeID: entry.cardCount ?? 1]
        }
        return SleeveMath.combinedCounts(
            base: game,
            expansions: entry.includedExpansionIDs.compactMap { gamesByID[$0] }
        )
    }

    private func totalCards(for entry: ListEntry) -> Int {
        combinedCounts(for: entry).values.reduce(0, +)
    }

    private func title(for entry: ListEntry) -> String {
        if let id = entry.gameID, let g = gamesByID[id] { return g.title }
        if let custom = entry.customTitle { return custom }
        if let w = entry.measuredWidthMM, let h = entry.measuredHeightMM {
            return "Measured \(units.compact(width: w, height: h))"
        }
        return "Measured card"
    }

    private var snapshotFingerprint: String {
        let entryPart = entries
            .map { "\($0.gameID ?? $0.customTitle ?? $0.sizeID):\($0.sleeveStatusRaw):\($0.includedExpansionIDs.sorted().joined(separator: ","))" }
            .joined(separator: "|")
        let stockPart = stocks.map { "\($0.sizeID)=\($0.ownedCount)" }.sorted().joined(separator: "|")
        return entryPart + "#" + stockPart
    }

    private func publishSnapshot() {
        let list = shoppingList.filter { $0.buy > 0 }
        SharedStore.save(SharedSnapshot(
            totalSleeves: list.reduce(0) { $0 + $1.buy },
            topLines: list.prefix(3).map { "\($0.buy)× \($0.size.shortName)" },
            gamesToSleeve: entries.filter { $0.sleeveStatus != .sleeved }.count,
            updatedAt: .now
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private var exportLines: [ShoppingListExport.Line] {
        shoppingList.filter { $0.buy > 0 }.map {
            ShoppingListExport.Line(count: $0.buy, sizeName: $0.size.shortName, dimensions: $0.size.long(units))
        }
    }

    @ViewBuilder private var shareMenu: some View {
        let text = ShoppingListExport.text(lines: exportLines)
        Menu {
            ShareLink(item: text) {
                Label("Share as text", systemImage: "text.alignleft")
            }
            .simultaneousGesture(TapGesture().onEnded { AppAnalytics.log(.shoppingListShared(format: "text")) })
            if let pdf = ShoppingListExport.pdf(lines: exportLines) {
                ShareLink(item: pdf) {
                    Label("Export as PDF", systemImage: "doc.richtext")
                }
                .simultaneousGesture(TapGesture().onEnded { AppAnalytics.log(.shoppingListShared(format: "pdf")) })
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "square.stack.3d.up",
            title: "Your collection is empty",
            message: "Add a game from its detail page, or measure a card — SleeveIt tracks your games, sleeves and shopping list here."
        ) {
            VStack(spacing: 12) {
                Button("Find a game", systemImage: "magnifyingglass") { selectedTab = .search }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Measure a card", systemImage: "viewfinder") { isMeasurePresented = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Actions

    /// Advances a game through Not sleeved → In progress → Sleeved → Not sleeved.
    private func cycleStatus(_ entry: ListEntry) {
        let next = SleeveStatus(rawValue: (entry.sleeveStatus.rawValue + 1) % 3) ?? .notSleeved
        entry.sleeveStatus = next
        try? context.save()
        AppAnalytics.log(.sleeveStatusChanged(status: next.label))
    }

    private func delete(_ entry: ListEntry) {
        context.delete(entry)
        try? context.save()
    }

    private func setStock(sizeID: String, owned: Int, brand: String) {
        if let existing = stocks.first(where: { $0.sizeID == sizeID }) {
            existing.ownedCount = max(0, owned)
            existing.brand = brand
        } else {
            context.insert(SleeveStock(sizeID: sizeID, ownedCount: max(0, owned), brand: brand))
        }
        try? context.save()
        AppAnalytics.log(.stockUpdated(sizeID: sizeID))
    }
}

// MARK: - Progress

private struct ProgressHeader: View {
    let done: Int
    let total: Int
    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(done == total ? "All sleeved" : "\(done) of \(total) sleeved")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if done == total, total > 0 {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.good)
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
    let counts: [String: Int]
    let expansionCount: Int
    let sizes: [SleeveSize]
    let units: UnitPreference
    let onCycleStatus: () -> Void
    let onOpen: () -> Void

    private var status: SleeveStatus { entry.sleeveStatus }
    private var isSleeved: Bool { status == .sleeved }

    private var title: String {
        if let game { return game.title }
        if let custom = entry.customTitle { return custom }
        if let w = entry.measuredWidthMM, let h = entry.measuredHeightMM {
            return "Measured · \(units.compact(width: w, height: h))"
        }
        return "Measured card"
    }

    private var chips: [String] {
        counts.sorted { $0.value > $1.value }.compactMap { sizeID, count in
            sizes.first { $0.id == sizeID }.map { "\(count)× \($0.compact(units))" }
        }
    }

    private var statusTint: Color {
        switch status {
        case .notSleeved: return .secondary.opacity(0.5)
        case .inProgress: return Theme.warning
        case .sleeved: return Theme.accent
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCycleStatus) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(statusTint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Status: \(status.label). Tap to change.")

            Button(action: onOpen) {
                HStack(spacing: 12) {
                    CoverPlaceholder(width: 36, height: 48).opacity(isSleeved ? 0.55 : 1)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 17, weight: .semibold))
                                .strikethrough(isSleeved)
                                .foregroundStyle(isSleeved ? .secondary : .primary)
                                .lineLimit(1)
                            if expansionCount > 0 {
                                Text("+\(expansionCount)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(chips.prefix(2), id: \.self) { chip in
                                Text(chip)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(isSleeved ? Color.secondary : Theme.accent)
                                    .padding(.vertical, 3).padding(.horizontal, 8)
                                    .background(
                                        (isSleeved ? Color.secondary.opacity(0.15) : Theme.accent.opacity(0.12)),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            if chips.count > 2 {
                                Text("+\(chips.count - 2)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if !entry.notes.isEmpty {
                                Image(systemName: "note.text")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private struct ShoppingRow: View {
    let line: MyListScreen.ShoppingLine
    let units: UnitPreference
    let onEditStock: () -> Void
    @State private var didCopy = false

    private var isCovered: Bool { line.buy == 0 }
    private var subtitle: String {
        line.owned > 0 ? "\(line.needed) needed · \(line.owned) in stock" : line.size.long(units)
    }

    var body: some View {
        Button(action: onEditStock) {
            HStack(spacing: 10) {
                if isCovered {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(Theme.good)
                } else {
                    Text("\(line.buy)×")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.size.shortName).font(.system(size: 15, weight: .semibold))
                    Text(isCovered ? "In stock — nothing to buy" : subtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !isCovered {
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

private struct StockRow: View {
    let size: SleeveSize
    let stock: SleeveStock?
    let needed: Int
    let units: UnitPreference
    let onEdit: () -> Void

    private var owned: Int { stock?.ownedCount ?? 0 }
    private var brand: String { stock?.brand ?? "" }

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(size.shortName).font(.system(size: 15, weight: .semibold))
                    Text(brand.isEmpty ? size.long(units) : "\(brand) · \(size.long(units))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(owned)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(owned > 0 ? Theme.accent : .secondary)
                    Text("owned").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Entry detail (status + notes)

private struct EntryDetailSheet: View {
    @Bindable var entry: ListEntry
    let game: Game?
    let counts: [String: Int]
    let sizes: [SleeveSize]
    let units: UnitPreference
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private var title: String {
        if let game { return game.title }
        if let custom = entry.customTitle { return custom }
        if let w = entry.measuredWidthMM, let h = entry.measuredHeightMM {
            return "Measured \(units.compact(width: w, height: h))"
        }
        return "Measured card"
    }

    private var deckLines: [(label: String, count: Int)] {
        counts.sorted { $0.value > $1.value }.compactMap { sizeID, count in
            sizes.first { $0.id == sizeID }.map { (label: "\(count)× \($0.shortName)", count: count) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sleeving status") {
                    Picker("Status", selection: Binding(
                        get: { entry.sleeveStatus },
                        set: { entry.sleeveStatus = $0; try? context.save()
                               AppAnalytics.log(.sleeveStatusChanged(status: $0.label)) }
                    )) {
                        ForEach(SleeveStatus.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notes") {
                    TextField("e.g. base game only, need premium sleeves…",
                              text: $entry.notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Cards") {
                    ForEach(deckLines, id: \.label) { line in
                        Text(line.label).font(.system(size: 14, design: .monospaced))
                    }
                }

                if let game {
                    Section {
                        NavigationLink {
                            GameDetailScreen(game: game)
                        } label: {
                            Label("Full game details & expansions", systemImage: "info.circle")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(); dismiss()
                    } label: {
                        Label("Remove from My Sleeves", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? context.save(); dismiss() }
                }
            }
        }
    }
}

// MARK: - Stock editor

private struct StockEditorSheet: View {
    let size: SleeveSize
    let units: UnitPreference
    let needed: Int
    let stock: SleeveStock?
    let onSave: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ownedText = ""
    @State private var brand = ""

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
                    HStack(spacing: 8) {
                        ForEach([50, 100], id: \.self) { pack in
                            Button("+\(pack)") { ownedText = String(owned + pack) }
                                .buttonStyle(.bordered).tint(Theme.accent)
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

                Section("Brand") {
                    TextField("e.g. Mayday, Gamegenic, Sleeve Kings", text: $brand)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle(size.shortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(owned, brand.trimmingCharacters(in: .whitespaces)); dismiss() }
                }
            }
            .onAppear {
                ownedText = String(stock?.ownedCount ?? 0)
                brand = stock?.brand ?? ""
            }
        }
    }
}
