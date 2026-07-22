import Foundation
import SwiftData

// MARK: - Sleeve size

/// A standard sleeve size. Catalog-owned: replaced wholesale on catalog sync.
@Model
final class SleeveSize {
    @Attribute(.unique) var id: String
    var name: String
    var widthMM: Double
    var heightMM: Double
    var tagline: String
    var blurb: String
    var examples: [String]
    var isCommon: Bool
    var sortIndex: Int

    init(
        id: String,
        name: String,
        widthMM: Double,
        heightMM: Double,
        tagline: String,
        blurb: String,
        examples: [String],
        isCommon: Bool,
        sortIndex: Int
    ) {
        self.id = id
        self.name = name
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.tagline = tagline
        self.blurb = blurb
        self.examples = examples
        self.isCommon = isCommon
        self.sortIndex = sortIndex
    }

    /// "Standard" rather than "Card Game (Standard)" — for badges and chips.
    var shortName: String {
        name.replacingOccurrences(of: " (Standard)", with: "")
    }
}

// MARK: - Game

@Model
final class Game {
    @Attribute(.unique) var id: String
    var title: String
    var publisher: String
    var year: Int

    /// Alternate titles a game is known by, used to match imports from
    /// BoardGameGeek where the canonical name may differ ("Settlers of Catan").
    var aliases: [String] = []

    /// The base game this expands, if any. Nil means this is a base game.
    /// Referenced by id (like all catalog cross-links) so a catalog refresh
    /// never orphans a relationship.
    var baseGameID: String?

    @Relationship(deleteRule: .cascade, inverse: \CardDeck.game)
    var decks: [CardDeck] = []

    init(
        id: String,
        title: String,
        publisher: String,
        year: Int,
        aliases: [String] = [],
        baseGameID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.year = year
        self.aliases = aliases
        self.baseGameID = baseGameID
    }

    var isExpansion: Bool { baseGameID != nil }

    /// Every key this game can be matched by.
    var matchKeys: Set<String> {
        Set(([title] + aliases).map(GameTitleMatcher.normalize))
    }

    var orderedDecks: [CardDeck] {
        decks.sorted { $0.sortIndex < $1.sortIndex }
    }

    var totalCards: Int {
        decks.reduce(0) { $0 + $1.count }
    }

    /// Distinct sleeve-size ids used by this game, in deck order.
    var sizeIDs: [String] {
        var seen = Set<String>()
        return orderedDecks.compactMap { seen.insert($0.sizeID).inserted ? $0.sizeID : nil }
    }

    /// Cards needed per sleeve-size id.
    var countsBySizeID: [String: Int] {
        decks.reduce(into: [:]) { totals, deck in
            totals[deck.sizeID, default: 0] += deck.count
        }
    }
}

/// One deck of same-sized cards within a game ("Bird cards", "Bonus cards").
@Model
final class CardDeck {
    var label: String
    var count: Int
    var sizeID: String
    var sortIndex: Int
    var game: Game?

    init(label: String, count: Int, sizeID: String, sortIndex: Int) {
        self.label = label
        self.count = count
        self.sizeID = sizeID
        self.sortIndex = sortIndex
    }
}

// MARK: - User data

/// An entry on My List — either a catalog game or a card the user measured.
@Model
final class ListEntry {
    @Attribute(.unique) var id: UUID
    var gameID: String?
    var measuredWidthMM: Double?
    var measuredHeightMM: Double?
    var sizeID: String
    var isOwned: Bool
    var addedAt: Date

    /// Expansions the user has folded into this game's sleeve total. Empty for
    /// base-game-only entries and for measured cards.
    var includedExpansionIDs: [String] = []

    init(
        id: UUID = UUID(),
        gameID: String? = nil,
        measuredWidthMM: Double? = nil,
        measuredHeightMM: Double? = nil,
        sizeID: String,
        isOwned: Bool = false,
        addedAt: Date = .now,
        includedExpansionIDs: [String] = []
    ) {
        self.id = id
        self.gameID = gameID
        self.measuredWidthMM = measuredWidthMM
        self.measuredHeightMM = measuredHeightMM
        self.sizeID = sizeID
        self.isOwned = isOwned
        self.addedAt = addedAt
        self.includedExpansionIDs = includedExpansionIDs
    }

    var isMeasurement: Bool { gameID == nil }
}

/// A card face the user has taught SleeveIt to recognise, stored as a Vision
/// feature print keyed to a game.
///
/// The personal, on-device corpus for artwork recognition — it starts empty and
/// grows as the user tags cards. (When iCloud sync lands in a future version,
/// this is one of the models that should follow the user across devices.)
@Model
final class LearnedCardPrint {
    @Attribute(.unique) var id: UUID
    var gameID: String
    var label: String
    /// NSKeyedArchiver-encoded `VNFeaturePrintObservation`.
    var printData: Data
    var createdAt: Date

    init(id: UUID = UUID(), gameID: String, label: String, printData: Data, createdAt: Date = .now) {
        self.id = id
        self.gameID = gameID
        self.label = label
        self.printData = printData
        self.createdAt = createdAt
    }
}

/// A game the user opened, for the Search screen's recents list.
@Model
final class RecentLookup {
    @Attribute(.unique) var gameID: String
    var viewedAt: Date

    init(gameID: String, viewedAt: Date = .now) {
        self.gameID = gameID
        self.viewedAt = viewedAt
    }
}

// MARK: - Sleeve math

enum SleeveMath {
    /// Cards-per-size for a base game plus a set of its expansions.
    ///
    /// Pure and catalog-driven so both the detail screen (live preview) and My
    /// List (shopping totals) compute expansion sleeve counts the same way.
    static func combinedCounts(base: Game, expansions: [Game]) -> [String: Int] {
        var totals = base.countsBySizeID
        for expansion in expansions {
            for (sizeID, count) in expansion.countsBySizeID {
                totals[sizeID, default: 0] += count
            }
        }
        return totals
    }
}

// MARK: - Title matching

/// Normalises game titles so imported names match catalog entries.
///
/// BoardGameGeek returns canonical names that often carry edition suffixes,
/// punctuation or articles the catalog doesn't use. Matching on a normalised
/// key is more robust than exact string equality, and — unlike matching on
/// BGG numeric ids — it cannot silently mis-link a game to the wrong entry.
enum GameTitleMatcher {
    static func normalize(_ title: String) -> String {
        var text = title.lowercased()

        // Drop parenthetical qualifiers: "Catan (Second Edition)" → "Catan".
        if let open = text.firstIndex(of: "(") {
            text = String(text[text.startIndex..<open])
        }
        // Drop dash-delimited subtitles: "Root – The Clockwork Expansion".
        for separator in [" – ", " — ", " - "] {
            if let range = text.range(of: separator) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }

        // Reduce punctuation to spaces so "Clank!" and "Clank" agree. Subtitles
        // after a colon are kept — "Ticket to Ride: Europe" is a different game
        // with a different card count, not an alias of the base game.
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        text = String(scalars)

        let stopWords: Set<String> = ["the", "a", "an"]
        return text
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
            .joined(separator: " ")
    }

    /// Finds the catalog game an imported title refers to, if any.
    static func match(_ importedTitle: String, in games: [Game]) -> Game? {
        let key = normalize(importedTitle)
        guard !key.isEmpty else { return nil }
        return games.first { $0.matchKeys.contains(key) }
    }
}
