import XCTest
import Vision
import CoreGraphics
@testable import SleeveIt

final class ArtworkRecognizerTests: XCTestCase {

    /// Draws a distinct test pattern so feature prints are discriminable —
    /// Vision keys on structure, so each image gets a different shape.
    private func patternImage(_ kind: Int, size: Int = 300) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        switch kind {
        case 0: // circle
            ctx.fillEllipse(in: CGRect(x: 60, y: 60, width: 180, height: 180))
        case 1: // diagonal stripes
            for i in stride(from: -size, to: size, by: 40) {
                ctx.fill(CGRect(x: i, y: 0, width: 20, height: size))
            }
        default: // corner squares
            ctx.fill(CGRect(x: 20, y: 20, width: 90, height: 90))
            ctx.fill(CGRect(x: 190, y: 190, width: 90, height: 90))
        }
        return ctx.makeImage()!
    }

    /// Generates a feature print, or skips the test when Vision can't run.
    ///
    /// `VNGenerateImageFeaturePrintRequest` needs the Neural Engine, which the
    /// iOS simulator doesn't provide ("Failed to create espresso context"). These
    /// tests therefore verify the pipeline only on a physical device; in the sim
    /// they skip rather than fail.
    private func print(_ kind: Int) throws -> VNFeaturePrintObservation {
        do {
            return try CardArtworkRecognizer.featurePrint(for: patternImage(kind))
        } catch {
            throw XCTSkip("Vision feature prints require a device (Neural Engine): \(error.localizedDescription)")
        }
    }

    func testSamePatternIsNearerThanADifferentPattern() throws {
        let circle = try print(0)
        let circleAgain = try print(0)
        let stripes = try print(1)

        let selfDistance = try XCTUnwrap(CardArtworkRecognizer.distance(circle, circleAgain))
        let crossDistance = try XCTUnwrap(CardArtworkRecognizer.distance(circle, stripes))

        XCTAssertLessThan(selfDistance, crossDistance,
                          "A re-rendered circle must be closer to the circle than stripes are")
    }

    func testRankingPutsTheMatchingPatternFirst() throws {
        let query = try print(2)
        let references = [
            (gameID: "circle", label: "c", print: try print(0)),
            (gameID: "stripes", label: "s", print: try print(1)),
            (gameID: "squares", label: "q", print: try print(2)),
        ]
        let ranked = CardArtworkRecognizer.rank(query: query, against: references)
        XCTAssertEqual(ranked.first?.gameID, "squares")
    }

    func testFeaturePrintSurvivesArchivingRoundTrip() throws {
        let original = try print(0)
        let data = try XCTUnwrap(CardArtworkRecognizer.archive(original))
        let restored = try XCTUnwrap(CardArtworkRecognizer.unarchive(data))

        // A restored print must still compare as identical to the original.
        let distance = try XCTUnwrap(CardArtworkRecognizer.distance(original, restored))
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testEmptyCorpusYieldsNoMatch() throws {
        let query = try print(0)
        XCTAssertNil(CardArtworkRecognizer.bestGameID(query: query, against: []))
        XCTAssertTrue(CardArtworkRecognizer.rank(query: query, against: []).isEmpty)
    }
}
