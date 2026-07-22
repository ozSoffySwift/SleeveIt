import XCTest
import SwiftData
@testable import SleeveIt

@MainActor
final class ExpansionTests: XCTestCase {

    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let container = try ModelContainer(
            for: Game.self, CardDeck.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeGame(_ id: String, base: String? = nil, decks: [(Int, String)]) -> Game {
        let game = Game(id: id, title: id, publisher: "", year: 2000, baseGameID: base)
        context.insert(game)
        for (index, spec) in decks.enumerated() {
            let deck = CardDeck(label: "d\(index)", count: spec.0, sizeID: spec.1, sortIndex: index)
            deck.game = game
            context.insert(deck)
        }
        return game
    }

    func testBaseAloneIsUnchanged() {
        let base = makeGame("wingspan", decks: [(170, "standard"), (26, "mini")])
        let counts = SleeveMath.combinedCounts(base: base, expansions: [])
        XCTAssertEqual(counts, ["standard": 170, "mini": 26])
    }

    func testExpansionCardsAreFoldedInPerSize() {
        let base = makeGame("wingspan", decks: [(170, "standard"), (26, "mini")])
        let european = makeGame("wingspan-eu", base: "wingspan", decks: [(81, "standard"), (5, "mini")])

        let counts = SleeveMath.combinedCounts(base: base, expansions: [european])

        // 170+81 standard, 26+5 mini — the whole point of the feature.
        XCTAssertEqual(counts["standard"], 251)
        XCTAssertEqual(counts["mini"], 31)
    }

    func testMultipleExpansionsAccumulate() {
        let base = makeGame("wingspan", decks: [(170, "standard")])
        let eu = makeGame("eu", base: "wingspan", decks: [(81, "standard")])
        let oceania = makeGame("oc", base: "wingspan", decks: [(95, "standard")])

        let counts = SleeveMath.combinedCounts(base: base, expansions: [eu, oceania])
        XCTAssertEqual(counts["standard"], 346)
    }

    func testExpansionCanIntroduceASizeTheBaseDoesNotUse() {
        let base = makeGame("game", decks: [(100, "standard")])
        let exp = makeGame("exp", base: "game", decks: [(20, "tarot")])

        let counts = SleeveMath.combinedCounts(base: base, expansions: [exp])
        XCTAssertEqual(counts["standard"], 100)
        XCTAssertEqual(counts["tarot"], 20)
    }

    func testIsExpansionReflectsBaseGameID() {
        let base = makeGame("base", decks: [(1, "standard")])
        let exp = makeGame("exp", base: "base", decks: [(1, "standard")])
        XCTAssertFalse(base.isExpansion)
        XCTAssertTrue(exp.isExpansion)
    }
}

final class CatalogExpansionIntegrityTests: XCTestCase {

    /// Every expansion's `baseGameID` must point at a real base game in the same
    /// payload, or the detail screen would list an expansion whose parent it
    /// can't find.
    func testBundledExpansionsReferenceRealBaseGames() throws {
        let url = try XCTUnwrap(
            Bundle(for: CatalogExpansionIntegrityTests.self)
                .url(forResource: "catalog", withExtension: "json")
            ?? Bundle.main.url(forResource: "catalog", withExtension: "json")
        )
        let payload = try JSONDecoder.catalog.decode(CatalogPayload.self, from: Data(contentsOf: url))

        let ids = Set(payload.games.map(\.id))
        let expansions = payload.games.filter { $0.baseGameID != nil }

        XCTAssertFalse(expansions.isEmpty, "v3 should ship at least one expansion")
        for expansion in expansions {
            let base = try XCTUnwrap(expansion.baseGameID)
            XCTAssertTrue(ids.contains(base), "\(expansion.title) references missing base '\(base)'")
            XCTAssertNotEqual(base, expansion.id, "\(expansion.title) lists itself as its base")
        }
    }
}
