import XCTest
import SwiftData
@testable import SleeveIt

final class GameTitleMatcherTests: XCTestCase {

    func testNormalizationStripsNoiseThatWouldBlockAMatch() {
        let n = GameTitleMatcher.normalize
        XCTAssertEqual(n("The Castles of Burgundy"), "castles of burgundy")
        XCTAssertEqual(n("Clank!"), "clank")
        XCTAssertEqual(n("Catan (Second Edition)"), "catan")
        XCTAssertEqual(n("  Azul  "), "azul")
        XCTAssertEqual(n("Root – The Underworld Expansion"), "root")
    }

    func testColonSubtitlesAreKeptBecauseTheyAreDifferentGames() {
        // Ticket to Ride: Europe has a different card count from the base game.
        // Collapsing them would silently give the user the wrong sleeve total.
        XCTAssertNotEqual(
            GameTitleMatcher.normalize("Ticket to Ride"),
            GameTitleMatcher.normalize("Ticket to Ride: Europe")
        )
    }

    func testMatchesByTitleAndByAlias() throws {
        let games = try makeGames()

        XCTAssertEqual(GameTitleMatcher.match("Wingspan", in: games)?.id, "wingspan")
        XCTAssertEqual(GameTitleMatcher.match("The Settlers of Catan", in: games)?.id, "catan")
        XCTAssertEqual(GameTitleMatcher.match("Seven Wonders", in: games)?.id, "seven-wonders")
        XCTAssertEqual(GameTitleMatcher.match("CATAN", in: games)?.id, "catan")
    }

    func testUnknownTitleDoesNotMatchAnything() throws {
        let games = try makeGames()
        XCTAssertNil(GameTitleMatcher.match("Some Game That Does Not Exist", in: games))
        XCTAssertNil(GameTitleMatcher.match("", in: games))
    }

    private func makeGames() throws -> [Game] {
        let container = try ModelContainer(
            for: Game.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let specs: [(String, String, [String])] = [
            ("wingspan", "Wingspan", []),
            ("catan", "Catan", ["Settlers of Catan", "The Settlers of Catan"]),
            ("seven-wonders", "7 Wonders", ["Seven Wonders"]),
            ("ticket-to-ride", "Ticket to Ride", []),
        ]
        return specs.map { spec in
            let game = Game(id: spec.0, title: spec.1, publisher: "", year: 2000, aliases: spec.2)
            context.insert(game)
            return game
        }
    }
}

final class BGGParsingTests: XCTestCase {

    func testParsesACollectionResponse() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <items totalitems="2" termsofuse="https://boardgamegeek.com/xmlapi/termsofuse">
            <item objecttype="thing" objectid="266192" subtype="boardgame" collid="1">
                <name sortindex="1">Wingspan</name>
                <yearpublished>2019</yearpublished>
                <status own="1"/>
            </item>
            <item objecttype="thing" objectid="13" subtype="boardgame" collid="2">
                <name sortindex="1">Catan</name>
                <yearpublished>1995</yearpublished>
                <status own="1"/>
            </item>
        </items>
        """
        let items = try BGGService.parse(Data(xml.utf8))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "266192")
        XCTAssertEqual(items[0].title, "Wingspan")
        XCTAssertEqual(items[0].year, 2019)
        XCTAssertEqual(items[1].title, "Catan")
    }

    func testEmptyCollectionParsesAsNoItemsRatherThanAnError() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <items totalitems="0"></items>
        """
        XCTAssertEqual(try BGGService.parse(Data(xml.utf8)).count, 0)
    }

    func testPrivateCollectionIsSurfacedAsItsOwnError() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <errors><error><message>Private collection</message></error></errors>
        """
        XCTAssertThrowsError(try BGGService.parse(Data(xml.utf8))) { error in
            XCTAssertEqual(error as? BGGError, .privateCollection)
        }
    }

    func testInvalidUserIsSurfacedAsItsOwnError() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <errors><error><message>Invalid username specified</message></error></errors>
        """
        XCTAssertThrowsError(try BGGService.parse(Data(xml.utf8))) { error in
            XCTAssertEqual(error as? BGGError, .userNotFound)
        }
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try BGGService.parse(Data("<items><item".utf8)))
    }

    func testRequestsWithoutATokenFailBeforeHittingTheNetwork() async throws {
        // The API rejects anonymous calls with a 401, so an unconfigured build
        // must say so rather than firing a request that cannot succeed.
        guard !BGGConfiguration.isConfigured else {
            throw XCTSkip("A BGG token is configured in this build")
        }
        do {
            _ = try await BGGService().ownedCollection(username: "someone")
            XCTFail("Expected a notConfigured error")
        } catch let error as BGGError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyUsernameIsRejected() async {
        do {
            _ = try await BGGService().ownedCollection(username: "   ")
            XCTFail("Expected an emptyUsername error")
        } catch let error as BGGError {
            XCTAssertEqual(error, .emptyUsername)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
