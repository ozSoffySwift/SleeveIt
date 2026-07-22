import XCTest
import SwiftData
@testable import SleeveIt

@MainActor
final class GameIdentifierTests: XCTestCase {

    private var context: ModelContext!
    private var sizes: [SleeveSize] = []
    private var games: [Game] = []

    override func setUp() async throws {
        try await super.setUp()
        let container = try ModelContainer(
            for: SleeveSize.self, Game.self, CardDeck.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)

        sizes = [
            ("standard", 63.5, 88.0),
            ("mini", 43.0, 65.0),
            ("tarot", 70.0, 120.0),
        ].enumerated().map { index, spec in
            let size = SleeveSize(
                id: spec.0, name: spec.0, widthMM: spec.1, heightMM: spec.2,
                tagline: "", blurb: "", examples: [], isCommon: false, sortIndex: index
            )
            context.insert(size)
            return size
        }

        // Wingspan: 170 standard + 26 mini. Tiny: 6 standard. Dixit: 84 tarot.
        games = [
            makeGame("wingspan", "Wingspan", [("Bird", 170, "standard"), ("Bonus", 26, "mini")]),
            makeGame("tiny", "Tiny Game", [("Cards", 6, "standard")]),
            makeGame("dixit", "Dixit", [("Vision", 84, "tarot")]),
        ]
    }

    private func makeGame(_ id: String, _ title: String, _ decks: [(String, Int, String)]) -> Game {
        let game = Game(id: id, title: title, publisher: "", year: 2000)
        context.insert(game)
        for (index, spec) in decks.enumerated() {
            let deck = CardDeck(label: spec.0, count: spec.1, sizeID: spec.2, sortIndex: index)
            deck.game = game
            context.insert(deck)
        }
        return game
    }

    private func size(_ id: String) -> SleeveSize {
        sizes.first { $0.id == id }!
    }

    // MARK: - Tests

    func testOnlyGamesUsingTheMeasuredSizeAreOffered() {
        let candidates = SizeBasedGameIdentifier().candidates(for: size("tarot"), in: games, knownGameIDs: [])

        XCTAssertEqual(candidates.map(\.game.id), ["dixit"])
    }

    func testCandidatesAreRankedByHowManyCardsOfThatSizeTheGameHas() {
        // A 63.5×88 card is likelier from a game with 170 of them than one with 6.
        let candidates = SizeBasedGameIdentifier().candidates(for: size("standard"), in: games, knownGameIDs: [])

        XCTAssertEqual(candidates.map(\.game.id), ["wingspan", "tiny"])
        XCTAssertEqual(candidates.first?.matchingCardCount, 170)
    }

    func testCandidateReportsTotalSleevesAcrossEveryDeckNotJustTheMatchedOne() {
        let candidates = SizeBasedGameIdentifier().candidates(for: size("standard"), in: games, knownGameIDs: [])
        let wingspan = try? XCTUnwrap(candidates.first)

        // The whole point of the paid flow: measuring one bird card should
        // surface all 196 sleeves, including the 26 mini ones.
        XCTAssertEqual(wingspan?.matchingCardCount, 170)
        XCTAssertEqual(wingspan?.totalSleeves, 196)
    }

    func testAGameIsOfferedWhenAnyOfItsDecksMatches() {
        // Wingspan should be found by its mini cards too, not only its birds.
        let candidates = SizeBasedGameIdentifier().candidates(for: size("mini"), in: games, knownGameIDs: [])

        XCTAssertEqual(candidates.map(\.game.id), ["wingspan"])
        XCTAssertEqual(candidates.first?.matchingCardCount, 26)
        XCTAssertEqual(candidates.first?.totalSleeves, 196)
    }

    func testNoCandidatesWhenNothingUsesTheSize() {
        let orphan = SleeveSize(
            id: "unused", name: "Unused", widthMM: 10, heightMM: 10,
            tagline: "", blurb: "", examples: [], isCommon: false, sortIndex: 99
        )
        XCTAssertTrue(SizeBasedGameIdentifier().candidates(for: orphan, in: games, knownGameIDs: []).isEmpty)
    }

    func testGamesTheUserOwnsAreRankedAboveBiggerStrangers() {
        // "tiny" has only 6 standard cards vs Wingspan's 170, but if the user
        // owns it, it is the likelier source and must lead.
        let candidates = SizeBasedGameIdentifier()
            .candidates(for: size("standard"), in: games, knownGameIDs: ["tiny"])

        XCTAssertEqual(candidates.map(\.game.id), ["tiny", "wingspan"])
        XCTAssertTrue(candidates[0].isKnownToUser)
        XCTAssertFalse(candidates[1].isKnownToUser)
    }

    func testEntitlementGatesTheIdentificationFeature() {
        // The identifier itself is not gated — the UI is — but the entitlement
        // must default to off so a build without StoreKit ships as free.
        XCTAssertFalse(Entitlements().isPro)
        XCTAssertTrue(Entitlements(isPro: true).isPro)
    }
}
