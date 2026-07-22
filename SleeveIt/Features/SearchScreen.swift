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
            .filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
            .sorted { lhs, rhs in
                // Prefix matches first, so "cat" surfaces Catan above Marvel Champions.
                let l = lhs.title.range(of: trimmed, options: [.caseInsensitive, .anchored]) != nil
                let r = rhs.title.range(of: trimmed, options: [.caseInsensitive, .anchored]) != nil
                return l == r ? lhs.title < rhs.title : l
            }
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
            .navigationTitle("Search")
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
        Button { isMeasurePresented = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 24))
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("Measure a Card")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 16)

                Text("Point your camera at any card to get its exact sleeve size.")
                    .font(.system(size: 15))
                    .opacity(0.9)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 3)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 34 / 255, green: 122 / 255, blue: 61 / 255), Theme.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(alignment: .topTrailing) {
                        PlayingCardDecoration()
                            .offset(x: 26, y: -14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            }
            .shadow(color: Theme.accent.opacity(0.4), radius: 18, y: 12)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
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

// MARK: - Playing-card decoration

/// A pair of fanned playing cards used to decorate the Measure CTA — portrait,
/// with a corner index and centre pip, so the banner reads as a playing card
/// rather than a bank/credit card.
private struct PlayingCardDecoration: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Back card, peeking and rotated the other way.
            card(suit: "suit.heart.fill", rank: "K")
                .rotationEffect(.degrees(-14), anchor: .bottomTrailing)
                .offset(x: -46, y: 20)
                .opacity(0.55)

            // Front card.
            card(suit: "suit.spade.fill", rank: "A")
                .rotationEffect(.degrees(10), anchor: .bottomTrailing)
        }
        .frame(width: 150, height: 150, alignment: .topTrailing)
    }

    private func card(suit: String, rank: String) -> some View {
        let width: CGFloat = 96
        let height: CGFloat = 134
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 2)
            }
            .overlay(alignment: .topLeading) {
                VStack(spacing: 1) {
                    Text(rank).font(.system(size: 13, weight: .bold))
                    Image(systemName: suit).font(.system(size: 9))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 8)
                .padding(.leading, 9)
            }
            .overlay {
                Image(systemName: suit)
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: width, height: height)
    }
}
