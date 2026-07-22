import XCTest
import SwiftData
@testable import SleeveIt

final class MeasurementTests: XCTestCase {

    // MARK: - Stabilizer

    func testStabilizerNeedsAFullWindowBeforeLocking() {
        var stabilizer = MeasurementStabilizer(windowSize: 5, toleranceMM: 1.0)
        for _ in 0..<4 {
            XCTAssertNil(stabilizer.accept(sample(63.5, 88.0)))
        }
        XCTAssertNotNil(stabilizer.accept(sample(63.5, 88.0)),
                        "The fifth sample completes the window and should lock")
    }

    func testStabilizerRejectsAJitteryWindow() {
        var stabilizer = MeasurementStabilizer(windowSize: 4, toleranceMM: 0.8)
        // A 3mm spread is well outside tolerance — a shaking hand must not lock.
        let widths = [63.5, 66.5, 63.5, 66.5]
        var result: CardMeasurement?
        for width in widths {
            result = stabilizer.accept(sample(width, 88.0))
        }
        XCTAssertNil(result)
    }

    func testStabilizerUsesMedianSoOneBadRaycastCannotSkewTheResult() {
        var stabilizer = MeasurementStabilizer(windowSize: 5, toleranceMM: 2.0)
        var result: CardMeasurement?
        // Four good samples and one outlier still inside tolerance.
        for width in [63.5, 63.5, 63.6, 63.5, 64.4] {
            result = stabilizer.accept(sample(width, 88.0))
        }
        XCTAssertEqual(result?.widthMM ?? 0, 63.5, accuracy: 0.05,
                       "Median should ignore the outlier rather than average it in")
    }

    func testNormalizationMakesLandscapeMeasurementsPortrait() {
        let sideways = CardMeasurement(widthMM: 88, heightMM: 63.5, confidence: 1)
        XCTAssertEqual(sideways.normalized.widthMM, 63.5)
        XCTAssertEqual(sideways.normalized.heightMM, 88)
    }

    func testStabilizerNormalizesBeforeComparing() {
        var stabilizer = MeasurementStabilizer(windowSize: 3, toleranceMM: 0.5)
        var result: CardMeasurement?
        // Same card, but one frame detected it rotated. Without normalization the
        // spread would look enormous and never lock.
        result = stabilizer.accept(sample(63.5, 88.0))
        result = stabilizer.accept(sample(88.0, 63.5))
        result = stabilizer.accept(sample(63.5, 88.0))
        XCTAssertNotNil(result)
    }

    // MARK: - Matching

    func testNearestSizePicksTheRightStandard() throws {
        let sizes = try makeSizes()

        let poker = CardMeasurement(widthMM: 63.4, heightMM: 88.1, confidence: 1)
        XCTAssertEqual(SleeveMatcher.nearest(to: poker, in: sizes)?.id, "standard")

        let tarot = CardMeasurement(widthMM: 69.8, heightMM: 119.6, confidence: 1)
        XCTAssertEqual(SleeveMatcher.nearest(to: tarot, in: sizes)?.id, "tarot")

        // Catan (59×92) and Standard (63.5×88) are close enough to be a real
        // confusion risk — this is the discrimination that matters most.
        let catan = CardMeasurement(widthMM: 59.2, heightMM: 91.8, confidence: 1)
        XCTAssertEqual(SleeveMatcher.nearest(to: catan, in: sizes)?.id, "catan")
    }

    func testConfidenceFlagsAnAmbiguousMatch() throws {
        let sizes = try makeSizes()

        let clean = CardMeasurement(widthMM: 63.4, heightMM: 88.1, confidence: 1)
        let cleanMatch = try XCTUnwrap(SleeveMatcher.nearest(to: clean, in: sizes))
        XCTAssertTrue(SleeveMatcher.isConfident(clean, cleanMatch))

        // An oddball card that isn't really any standard should not be presented
        // as a confident recommendation.
        let odd = CardMeasurement(widthMM: 61, heightMM: 94, confidence: 1)
        let oddMatch = try XCTUnwrap(SleeveMatcher.nearest(to: odd, in: sizes))
        XCTAssertFalse(SleeveMatcher.isConfident(odd, oddMatch))
    }

    // MARK: - Units

    func testMillimetreFormattingTrimsWholeNumbersOnly() {
        let mm = UnitPreference.millimeters
        XCTAssertEqual(mm.compact(width: 63.5, height: 88), "63.5×88")
        XCTAssertEqual(mm.long(width: 43, height: 65), "43 × 65 mm")
    }

    func testInchConversion() {
        let inches = UnitPreference.inches
        // 63.5mm is exactly 2.5in — the classic poker card.
        XCTAssertEqual(inches.compact(width: 63.5, height: 88.9), "2.50×3.50")
    }

    // MARK: - Helpers

    private func sample(_ width: Double, _ height: Double) -> CardMeasurement {
        CardMeasurement(widthMM: width, heightMM: height, confidence: 1)
    }

    private func makeSizes() throws -> [SleeveSize] {
        let container = try ModelContainer(
            for: SleeveSize.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let specs: [(String, String, Double, Double)] = [
            ("mini-american", "Mini American", 41, 63),
            ("mini", "Mini", 43, 65),
            ("standard-american", "Standard American", 57.5, 89),
            ("standard", "Card Game (Standard)", 63.5, 88),
            ("catan", "Catan", 59, 92),
            ("seven-wonders", "7 Wonders", 65, 100),
            ("tarot", "Tarot", 70, 120),
        ]
        return specs.enumerated().map { index, spec in
            let size = SleeveSize(
                id: spec.0, name: spec.1, widthMM: spec.2, heightMM: spec.3,
                tagline: "", blurb: "", examples: [], isCommon: spec.0 == "standard",
                sortIndex: index
            )
            context.insert(size)
            return size
        }
    }
}

// MARK: - Catalog

final class CatalogTests: XCTestCase {

    func testBundledCatalogDecodesAndIsInternallyConsistent() throws {
        let bundle = Bundle(for: CatalogTests.self)
        // The seed lives in the app bundle; tests host into it.
        let url = try XCTUnwrap(
            bundle.url(forResource: "catalog", withExtension: "json")
            ?? Bundle.main.url(forResource: "catalog", withExtension: "json"),
            "catalog.json must be bundled with the app"
        )

        let payload = try JSONDecoder.catalog.decode(CatalogPayload.self, from: Data(contentsOf: url))

        XCTAssertGreaterThan(payload.version, 0)
        XCTAssertFalse(payload.sizes.isEmpty)
        XCTAssertFalse(payload.games.isEmpty)

        // Every deck must reference a size that actually exists, or the detail
        // screen silently renders a row with no badge.
        let sizeIDs = Set(payload.sizes.map(\.id))
        for game in payload.games {
            XCTAssertFalse(game.decks.isEmpty, "\(game.title) has no decks")
            for deck in game.decks {
                XCTAssertTrue(
                    sizeIDs.contains(deck.sizeID),
                    "\(game.title) → \(deck.label) references unknown size '\(deck.sizeID)'"
                )
                XCTAssertGreaterThan(deck.count, 0, "\(game.title) → \(deck.label) has no cards")
            }
        }

        XCTAssertEqual(Set(payload.games.map(\.id)).count, payload.games.count, "Duplicate game ids")
        XCTAssertEqual(sizeIDs.count, payload.sizes.count, "Duplicate size ids")
    }

    func testWingspanTotalsMatchTheDesign() throws {
        let container = try ModelContainer(
            for: Game.self, CardDeck.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let game = Game(id: "wingspan", title: "Wingspan", publisher: "Stonemaier Games", year: 2019)
        context.insert(game)
        for (index, spec) in [("Bird cards", 170, "standard"), ("Bonus cards", 26, "mini")].enumerated() {
            let deck = CardDeck(label: spec.0, count: spec.1, sizeID: spec.2, sortIndex: index)
            deck.game = game
            context.insert(deck)
        }

        XCTAssertEqual(game.totalCards, 196)
        XCTAssertEqual(game.sizeIDs, ["standard", "mini"])
        XCTAssertEqual(game.countsBySizeID, ["standard": 170, "mini": 26])
    }
}
