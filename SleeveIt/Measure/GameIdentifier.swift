import Foundation

/// A game a measured card might have come from.
struct GameCandidate: Identifiable, Equatable {
    var game: Game
    /// Cards in this game that share the measured size.
    var matchingCardCount: Int
    /// Total sleeves the whole game needs, across every deck.
    var totalSleeves: Int

    /// The user already owns or listed this game, so it's a far likelier source
    /// than an arbitrary catalog entry of the same size.
    var isKnownToUser: Bool = false

    var id: String { game.id }

    static func == (lhs: GameCandidate, rhs: GameCandidate) -> Bool {
        lhs.game.id == rhs.game.id
    }
}

/// Works out which game a measured card belongs to.
///
/// Abstracted so the identification strategy can be replaced without touching
/// the UI — see `SizeBasedGameIdentifier` for what ships today and the note
/// there about what real artwork recognition would require.
protocol GameIdentifying {
    /// - Parameter knownGameIDs: games the user owns or has listed — from My
    ///   List and any imported BoardGameGeek collection.
    func candidates(
        for size: SleeveSize,
        in games: [Game],
        knownGameIDs: Set<String>
    ) -> [GameCandidate]
}

/// Identifies candidate games by card size.
///
/// **This narrows, it does not recognise.** A 63.5×88 card could be from any of
/// dozens of games, so this returns every catalog game that uses the measured
/// size and lets the user confirm which one. That is honest about what the data
/// supports, and still delivers the useful part: once the user picks, SleeveIt
/// knows every deck in that game and can fill the basket in one tap.
///
/// True automatic recognition would mean matching the card's *artwork* against
/// a reference image per card — `VNGenerateImageFeaturePrintRequest` can compute
/// the similarity, but it needs a labelled image corpus that does not exist yet.
/// Building that corpus is the real work; this protocol is where it would plug in.
struct SizeBasedGameIdentifier: GameIdentifying {
    func candidates(
        for size: SleeveSize,
        in games: [Game],
        knownGameIDs: Set<String> = []
    ) -> [GameCandidate] {
        games.compactMap { game -> GameCandidate? in
            let matching = game.countsBySizeID[size.id] ?? 0
            guard matching > 0 else { return nil }
            return GameCandidate(
                game: game,
                matchingCardCount: matching,
                totalSleeves: game.totalCards,
                isKnownToUser: knownGameIDs.contains(game.id)
            )
        }
        .sorted { lhs, rhs in
            // Games the user actually owns come first. The standard 63.5×88 size
            // is used by most of the catalog, so size alone barely narrows the
            // field — but "which of the games you own is this?" usually has a
            // handful of answers, which is what makes the flow useful.
            if lhs.isKnownToUser != rhs.isKnownToUser {
                return lhs.isKnownToUser
            }
            // Then by how many cards of that size the game has: a card is likelier
            // from a game with 380 of them than one with 6.
            if lhs.matchingCardCount != rhs.matchingCardCount {
                return lhs.matchingCardCount > rhs.matchingCardCount
            }
            return lhs.game.title < rhs.game.title
        }
    }
}
