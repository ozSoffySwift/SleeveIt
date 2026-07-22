import XCTest
import CoreGraphics
@testable import SleeveIt

final class ReferenceMeasurerTests: XCTestCase {

    /// A synthetic photo: a 63.5×88 mm card and a US quarter (24.26 mm), both at
    /// a known 10 points-per-mm scale, should read back the card's real size.
    func testRecoversKnownCardSizeFromAKnownReference() throws {
        let ppmm = 10.0 // points per mm in this fake image

        // Card quad, 63.5 × 88 mm at 10 pt/mm = 635 × 880 pt.
        let corners = [
            CGPoint(x: 100, y: 100),
            CGPoint(x: 100 + 63.5 * ppmm, y: 100),
            CGPoint(x: 100 + 63.5 * ppmm, y: 100 + 88 * ppmm),
            CGPoint(x: 100, y: 100 + 88 * ppmm),
        ]
        // Quarter diameter marked: 24.26 mm × 10 = 242.6 pt.
        let refA = CGPoint(x: 100, y: 1100)
        let refB = CGPoint(x: 100 + 24.26 * ppmm, y: 1100)

        let result = try XCTUnwrap(ReferenceMeasurer.measure(
            cardCorners: corners,
            referenceEndpoints: (refA, refB),
            reference: .usQuarter
        ))

        XCTAssertEqual(result.widthMM, 63.5, accuracy: 0.1)
        XCTAssertEqual(result.heightMM, 88.0, accuracy: 0.1)
    }

    func testScaleIsInvariantToImageResolution() throws {
        // Same card + reference, photographed at 3× the scale, must give the
        // same millimetres — the reference cancels the unknown scale.
        func measureAt(_ ppmm: Double) throws -> CardMeasurement {
            let corners = [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 63.5 * ppmm, y: 0),
                CGPoint(x: 63.5 * ppmm, y: 88 * ppmm),
                CGPoint(x: 0, y: 88 * ppmm),
            ]
            let ref = (CGPoint(x: 0, y: 1000), CGPoint(x: 24.26 * ppmm, y: 1000))
            return try XCTUnwrap(ReferenceMeasurer.measure(
                cardCorners: corners, referenceEndpoints: ref, reference: .usQuarter))
        }

        let low = try measureAt(4)
        let high = try measureAt(12)
        XCTAssertEqual(low.widthMM, high.widthMM, accuracy: 0.05)
        XCTAssertEqual(low.heightMM, high.heightMM, accuracy: 0.05)
    }

    func testResultIsNormalizedToPortrait() throws {
        // Card marked sideways (landscape) still reports width < height.
        let ppmm = 10.0
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 88 * ppmm, y: 0),
            CGPoint(x: 88 * ppmm, y: 63.5 * ppmm),
            CGPoint(x: 0, y: 63.5 * ppmm),
        ]
        let ref = (CGPoint(x: 0, y: 1000), CGPoint(x: 24.26 * ppmm, y: 1000))
        let result = try XCTUnwrap(ReferenceMeasurer.measure(
            cardCorners: corners, referenceEndpoints: ref, reference: .usQuarter))

        XCTAssertLessThan(result.widthMM, result.heightMM)
        XCTAssertEqual(result.widthMM, 63.5, accuracy: 0.1)
    }

    func testCreditCardReferenceWorks() throws {
        let ppmm = 8.0
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 65 * ppmm, y: 0),
            CGPoint(x: 65 * ppmm, y: 100 * ppmm),
            CGPoint(x: 0, y: 100 * ppmm),
        ]
        // Credit card long edge = 85.6 mm.
        let ref = (CGPoint(x: 0, y: 1000), CGPoint(x: 85.6 * ppmm, y: 1000))
        let result = try XCTUnwrap(ReferenceMeasurer.measure(
            cardCorners: corners, referenceEndpoints: ref, reference: .creditCard))

        XCTAssertEqual(result.widthMM, 65, accuracy: 0.2)
        XCTAssertEqual(result.heightMM, 100, accuracy: 0.2)
    }

    func testDegenerateReferenceLengthReturnsNil() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                       CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        // Both endpoints coincident → no scale to derive.
        let ref = (CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5))
        XCTAssertNil(ReferenceMeasurer.measure(
            cardCorners: corners, referenceEndpoints: ref, reference: .usQuarter))
    }

    func testWrongCornerCountReturnsNil() {
        let ref = (CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        XCTAssertNil(ReferenceMeasurer.measure(
            cardCorners: [.zero, .zero, .zero], referenceEndpoints: ref, reference: .usQuarter))
    }

    func testMatchedMeasurementSnapsToStandard() throws {
        // End-to-end sanity: a reference measurement of a poker card should match
        // the Standard sleeve, proving the same CardMeasurement feeds SleeveMatcher.
        let ppmm = 10.0
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 63.5 * ppmm, y: 0),
            CGPoint(x: 63.5 * ppmm, y: 88 * ppmm),
            CGPoint(x: 0, y: 88 * ppmm),
        ]
        let ref = (CGPoint(x: 0, y: 1000), CGPoint(x: 24.26 * ppmm, y: 1000))
        let measurement = try XCTUnwrap(ReferenceMeasurer.measure(
            cardCorners: corners, referenceEndpoints: ref, reference: .usQuarter))

        let standard = SleeveSize(
            id: "standard", name: "Card Game (Standard)", widthMM: 63.5, heightMM: 88,
            tagline: "", blurb: "", examples: [], isCommon: true, sortIndex: 0)
        let mini = SleeveSize(
            id: "mini", name: "Mini", widthMM: 43, heightMM: 65,
            tagline: "", blurb: "", examples: [], isCommon: false, sortIndex: 1)

        XCTAssertEqual(SleeveMatcher.nearest(to: measurement, in: [mini, standard])?.id, "standard")
    }
}
