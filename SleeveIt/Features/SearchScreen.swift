import SwiftUI
import SwiftData

struct SearchScreen: View {
    @Environment(\.modelContext) private var context
    @AppStorage("units") private var units: UnitPreference = .millimeters

    @Query(sort: \Game.title) private var games: [Game]
    @Query(sort: \RecentLookup.viewedAt, order: .reverse) private var recents: [RecentLookup]

    @State private var query = ""
    @State private var isAddGamePresented = false
    @Binding var isMeasurePresented: Bool

    private var results: [Game] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return games
            .filter { game in
                // Aliases count too, so "Avalon", "MTG" or "Settlers of Catan"
                // find their games despite different canonical titles.
                game.title.localizedCaseInsensitiveContains(trimmed)
                    || game.aliases.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
            .sorted { lhs, rhs in
                // Prefix matches first, so "cat" surfaces Catan above Marvel Champions.
                let l = lhs.title.range(of: trimmed, options: [.caseInsensitive, .anchored]) != nil
                let r = rhs.title.range(of: trimmed, options: [.caseInsensitive, .anchored]) != nil
                return l == r ? lhs.title < rhs.title : l
            }
            .prefix(120)
            .map { $0 }
    }

    private var recentGames: [Game] {
        recents.prefix(6).compactMap { recent in
            games.first { $0.id == recent.gameID }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    idleContent
                } else if results.isEmpty {
                    noResults
                } else {
                    List(results) { game in
                        NavigationLink(value: game) {
                            GameRow(game: game, units: units)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Measure")
            // Inline so the title sits on the same row as the settings gear,
            // instead of as a large title on the row below.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Game.self) { game in
                GameDetailScreen(game: game)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsScreen() } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search a game…")
    }

    // MARK: - Idle

    private var idleContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                measureCTA

                if recentGames.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "No recent lookups yet",
                        message: "Search a game or measure a card to get started.",
                        tagline: "Sleeve it, don't leave it."
                    )
                    .padding(.top, 42)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(0.3)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(recentGames.enumerated()), id: \.element.id) { index, game in
                                NavigationLink(value: game) {
                                    GameRow(game: game, units: units)
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 16)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)

                                if index < recentGames.count - 1 {
                                    Divider().padding(.leading, 62)
                                }
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .padding(.top, 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
    }

    private var measureCTA: some View {
        // Shaped like a real Card Game (Standard) card: 63.5 × 88 aspect ratio,
        // portrait, centred — so the primary action itself looks like a card.
        let cardWidth: CGFloat = 208
        let cardHeight = cardWidth * 88 / 63.5

        return Button { isMeasurePresented = true } label: {
            VStack(spacing: 0) {
                // Playing-card corner index, top-left.
                cornerIndex
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)

                Image(systemName: "viewfinder")
                    .font(.system(size: 44, weight: .regular))
                    .frame(width: 68, height: 68)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Measure\na Card")
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                Text("Size any card with your camera")
                    .font(.system(size: 13))
                    .opacity(0.9)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                Spacer(minLength: 8)

                // Mirrored index, bottom-right, like a playing card.
                cornerIndex
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .rotationEffect(.degrees(180))
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(width: cardWidth, height: cardHeight)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 34 / 255, green: 122 / 255, blue: 61 / 255), Theme.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.4), radius: 18, y: 12)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    /// The small rank + suit index printed in a playing card's corner.
    private var cornerIndex: some View {
        VStack(spacing: 0) {
            Text("A").font(.system(size: 15, weight: .bold))
            Image(systemName: "suit.spade.fill").font(.system(size: 11))
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private var noResults: some View {
        EmptyStateView(
            icon: "magnifyingglass",
            title: "No games found",
            message: "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”. Try a shorter search, or measure the card yourself."
        ) {
            VStack(spacing: 12) {
                Button("Measure a card", systemImage: "viewfinder") { isMeasurePresented = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Add this game", systemImage: "plus.circle") { isAddGamePresented = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $isAddGamePresented) {
            CorrectionScreen(mode: .newGame(prefilledTitle: query.trimmingCharacters(in: .whitespaces)))
        }
    }
}

// MARK: - Row

struct GameRow: View {
    let game: Game
    let units: UnitPreference
    @Query(sort: \SleeveSize.sortIndex) private var sizes: [SleeveSize]

    private var summary: String {
        let ids = game.sizeIDs
        if ids.count == 1, let size = sizes.first(where: { $0.id == ids[0] }) {
            return size.long(units)
        }
        return "\(ids.count) sizes"
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverPlaceholder(width: 34, height: 44, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(game.title)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(game.publisher) · \(summary)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
    }
}
