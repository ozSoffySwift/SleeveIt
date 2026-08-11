import XCTest
import SwiftData
import simd
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

    // MARK: - Vision → ARKit coordinate conversion

    /// The mapping that places raycasts on the card's actual corners. Vision
    /// points are portrait-oriented with a bottom-left origin; ARKit's raycast
    /// wants the sensor-native landscape image with a top-left origin. Portrait
    /// is the sensor rotated 90° clockwise, so the inverse is (x,y) → (1−y, 1−x).
    /// This being wrong is invisible in code review and fatal at runtime — the
    /// scan can never lock — so the geometry is pinned here.
    func testVisionToSensorConversionMapsKnownCorners() {
        let convert = ARCardMeasurer.sensorPoint(fromVisionPoint:)

        // Centre is rotation-invariant.
        XCTAssertEqual(convert(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5))

        // Portrait top-centre lives on the sensor's left-edge middle.
        XCTAssertEqual(convert(CGPoint(x: 0.5, y: 1.0)), CGPoint(x: 0.0, y: 0.5))

        // Portrait bottom-left corner is the sensor's bottom-right.
        XCTAssertEqual(convert(CGPoint(x: 0.0, y: 0.0)), CGPoint(x: 1.0, y: 1.0))

        // Portrait top-right corner is the sensor's top-left.
        XCTAssertEqual(convert(CGPoint(x: 1.0, y: 1.0)), CGPoint(x: 0.0, y: 0.0))
    }

    func testVisionToSensorConversionIsNotAPlainYFlip() {
        // The original bug: only flipping y. For any off-axis point the two
        // mappings must disagree, or this test would let the bug back in.
        let point = CGPoint(x: 0.2, y: 0.7)
        let correct = ARCardMeasurer.sensorPoint(fromVisionPoint: point)
        let plainFlip = CGPoint(x: point.x, y: 1 - point.y)
        XCTAssertNotEqual(correct, plainFlip)
    }

    // MARK: - Ray geometry

    func testCameraRayThroughPrincipalPointLooksStraightAhead() {
        let direction = ARCardMeasurer.cameraRayDirection(
            pixelX: 960, pixelY: 540, fx: 1000, fy: 1000, ox: 960, oy: 540)
        XCTAssertEqual(direction.x, 0, accuracy: 1e-6)
        XCTAssertEqual(direction.y, 0, accuracy: 1e-6)
        XCTAssertEqual(direction.z, -1, accuracy: 1e-6)
    }

    func testRayPlaneIntersection() {
        // Straight down from 1m above the origin onto the ground plane.
        let hit = ARCardMeasurer.intersect(
            rayOrigin: simd_float3(0, 1, 0), rayDirection: simd_float3(0, -1, 0),
            planePoint: simd_float3(0, 0, 0), planeNormal: simd_float3(0, 1, 0))
        XCTAssertEqual(hit, simd_float3(0, 0, 0))

        // Parallel ray never intersects.
        XCTAssertNil(ARCardMeasurer.intersect(
            rayOrigin: simd_float3(0, 1, 0), rayDirection: simd_float3(1, 0, 0),
            planePoint: simd_float3(0, 0, 0), planeNormal: simd_float3(0, 1, 0)))

        // A plane behind the ray is rejected.
        XCTAssertNil(ARCardMeasurer.intersect(
            rayOrigin: simd_float3(0, 1, 0), rayDirection: simd_float3(0, 1, 0),
            planePoint: simd_float3(0, 0, 0), planeNormal: simd_float3(0, 1, 0)))
    }

    /// End-to-end synthetic check of the unprojection path: a 63.5×88mm card on
    /// a table, camera 30cm directly above — project each corner to pixels with
    /// the same intrinsics model, then recover the corners via
    /// `cameraRayDirection` + `intersect` and confirm the edge lengths come back
    /// as the card's true size.
    func testCornerRecoveryReproducesCardDimensions() throws {
        let (fx, fy, ox, oy): (Float, Float, Float, Float) = (1400, 1400, 960, 540)

        // Camera at (0, 0.3, 0) looking straight down: x_cam = world +x,
        // y_cam = world -z, z_cam = world +y (camera looks along -z_cam = -y).
        let rotation = simd_float3x3(columns: (
            simd_float3(1, 0, 0),
            simd_float3(0, 0, -1),
            simd_float3(0, 1, 0)
        ))
        let cameraPosition = simd_float3(0, 0.3, 0)

        // Card corners on the table plane (y = 0), 63.5 × 88 mm.
        let hw: Float = 0.03175
        let hh: Float = 0.044
        var worldCorners: [simd_float3] = []
        worldCorners.append(simd_float3(-hw, 0, -hh))
        worldCorners.append(simd_float3(hw, 0, -hh))
        worldCorners.append(simd_float3(hw, 0, hh))
        worldCorners.append(simd_float3(-hw, 0, hh))

        // Project to pixels (camera convention: -z forward, image y down).
        let pixels = worldCorners.map { world -> (Float, Float) in
            let cam = rotation.transpose * (world - cameraPosition)
            let u = fx * (cam.x / -cam.z) + ox
            let v = fy * (-cam.y / -cam.z) + oy
            return (u, v)
        }

        // Recover via the production primitives.
        let recovered = try pixels.map { (u, v) -> simd_float3 in
            let dirCam = ARCardMeasurer.cameraRayDirection(
                pixelX: u, pixelY: v, fx: fx, fy: fy, ox: ox, oy: oy)
            let dirWorld = rotation * dirCam
            return try XCTUnwrap(ARCardMeasurer.intersect(
                rayOrigin: cameraPosition, rayDirection: dirWorld,
                planePoint: .zero, planeNormal: simd_float3(0, 1, 0)))
        }

        let width = Double(simd_distance(recovered[0], recovered[1])) * 1000
        let height = Double(simd_distance(recovered[1], recovered[2])) * 1000
        XCTAssertEqual(width, 63.5, accuracy: 0.05)
        XCTAssertEqual(height, 88.0, accuracy: 0.05)
    }

    // MARK: - LiDAR depth unprojection

    func testCameraPointAtPrincipalPointSitsOnTheOpticalAxis() {
        let point = ARCardMeasurer.cameraPoint(
            pixelX: 960, pixelY: 540, depth: 0.42, fx: 1400, fy: 1400, ox: 960, oy: 540)
        XCTAssertEqual(point.x, 0, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0, accuracy: 1e-6)
        XCTAssertEqual(point.z, -0.42, accuracy: 1e-6)
    }

    /// ARDepthData depth is z-distance along the optical axis, not ray length —
    /// so the unprojected point must land exactly at z = −depth *and* on the
    /// same ray `cameraRayDirection` builds for that pixel.
    func testCameraPointAgreesWithTheRayModel() {
        let (fx, fy, ox, oy): (Float, Float, Float, Float) = (1400, 1300, 960, 540)
        let (u, v, d): (Float, Float, Float) = (1200, 300, 0.35)

        let point = ARCardMeasurer.cameraPoint(
            pixelX: u, pixelY: v, depth: d, fx: fx, fy: fy, ox: ox, oy: oy)
        XCTAssertEqual(point.z, -d, accuracy: 1e-6)

        let ray = ARCardMeasurer.cameraRayDirection(
            pixelX: u, pixelY: v, fx: fx, fy: fy, ox: ox, oy: oy)
        let cross = simd_cross(simd_normalize(point), ray)
        XCTAssertEqual(simd_length(cross), 0, accuracy: 1e-5, "point must lie on the pixel's ray")
    }

    // MARK: - Rectangle selection

    private func candidate(
        confidence: Float, area: Double, at center: CGPoint
    ) -> ARCardMeasurer.RectCandidate {
        ARCardMeasurer.RectCandidate(confidence: confidence, area: area, center: center)
    }

    /// Cards with printed inner frames produce two concentric detections, and
    /// the inner one often carries the higher confidence. Picking it silently
    /// shrinks the measurement — the outer (larger) rectangle is the card.
    func testSelectionPrefersOuterEdgeOverConfidentInnerFrame() {
        let index = ARCardMeasurer.bestCandidateIndex([
            candidate(confidence: 0.95, area: 0.040, at: CGPoint(x: 0.5, y: 0.5)),  // inner art frame
            candidate(confidence: 0.80, area: 0.085, at: CGPoint(x: 0.5, y: 0.5)),  // card edge
        ])
        XCTAssertEqual(index, 1)
    }

    /// A bigger rectangle at the edge of the frame (notebook, placemat) must
    /// not out-rank the card the user is actually aiming at.
    func testSelectionPrefersTheAimedCardOverALargerBystander() {
        let index = ARCardMeasurer.bestCandidateIndex([
            candidate(confidence: 0.9, area: 0.30, at: CGPoint(x: 0.9, y: 0.85)),  // placemat corner
            candidate(confidence: 0.9, area: 0.06, at: CGPoint(x: 0.52, y: 0.47)), // aimed card
        ])
        XCTAssertEqual(index, 1)
    }

    func testSelectionFallsBackToOffCentreWhenNothingIsAimed() {
        let index = ARCardMeasurer.bestCandidateIndex([
            candidate(confidence: 0.9, area: 0.06, at: CGPoint(x: 0.15, y: 0.8)),
        ])
        XCTAssertEqual(index, 0)
    }

    func testSelectionReturnsNilForNoCandidates() {
        XCTAssertNil(ARCardMeasurer.bestCandidateIndex([]))
    }

    func testQuadAreaOfUnitSquare() {
        let square = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
        ]
        XCTAssertEqual(ARCardMeasurer.quadArea(of: square), 1.0, accuracy: 1e-9)
        // Winding order must not flip the sign.
        XCTAssertEqual(ARCardMeasurer.quadArea(of: square.reversed()), 1.0, accuracy: 1e-9)
    }

    // MARK: - Sub-pixel edge refinement

    func testFitLineRecoversAKnownLine() throws {
        // Points on y = 2x + 1 with tiny alternating noise.
        let points = (0..<20).map { i -> CGPoint in
            let x = Double(i)
            return CGPoint(x: x, y: 2 * x + 1 + (i.isMultiple(of: 2) ? 0.01 : -0.01))
        }
        let line = try XCTUnwrap(EdgeRefinement.fitLine(points))
        let slope = line.direction.dy / line.direction.dx
        XCTAssertEqual(slope, 2.0, accuracy: 0.01)
        XCTAssertEqual(EdgeRefinement.distance(from: CGPoint(x: 5, y: 11), to: line),
                       0, accuracy: 0.02)
    }

    func testFitLineHandlesVerticalEdges() throws {
        // A least-squares y=f(x) fit would blow up here; total least squares must not.
        let points = (0..<20).map { CGPoint(x: 100.0, y: Double($0)) }
        let line = try XCTUnwrap(EdgeRefinement.fitLine(points))
        XCTAssertEqual(abs(line.direction.dy), 1.0, accuracy: 1e-6)
        XCTAssertEqual(EdgeRefinement.distance(from: CGPoint(x: 103, y: 10), to: line),
                       3, accuracy: 1e-6)
    }

    func testLineIntersectionFindsTheCorner() throws {
        let horizontal = EdgeRefinement.Line(
            point: CGPoint(x: 0, y: 5), direction: CGVector(dx: 1, dy: 0))
        let vertical = EdgeRefinement.Line(
            point: CGPoint(x: 7, y: 0), direction: CGVector(dx: 0, dy: 1))
        let corner = try XCTUnwrap(EdgeRefinement.intersection(horizontal, vertical))
        XCTAssertEqual(corner.x, 7, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 5, accuracy: 1e-9)
        XCTAssertNil(EdgeRefinement.intersection(horizontal, horizontal), "parallel lines")
    }

    func testParabolicPeakInterpolatesSubSample() {
        // Symmetric samples peak exactly at the centre.
        XCTAssertEqual(EdgeRefinement.parabolicPeak(1, 2, 1), 0, accuracy: 1e-9)
        // A stronger right neighbour pulls the vertex right; bounded to ±0.5.
        XCTAssertGreaterThan(EdgeRefinement.parabolicPeak(1, 2, 1.9), 0)
        XCTAssertLessThanOrEqual(abs(EdgeRefinement.parabolicPeak(0, 1, 1)), 0.5)
    }

    // MARK: - LiDAR plane fit

    func testPlaneFitRecoversAKnownTable() throws {
        // Points on the plane y = 0.02x - 0.01z + 0.5, i.e. a slightly tilted table.
        var points: [simd_float3] = []
        for i in 0..<5 {
            for j in 0..<5 {
                let x = Float(i) * 0.02 - 0.04
                let z = Float(j) * 0.02 - 0.04
                points.append(simd_float3(x, 0.02 * x - 0.01 * z + 0.5, z))
            }
        }
        let fit = try XCTUnwrap(ARCardMeasurer.fitHorizontalPlane(points))
        // The fitted normal must be perpendicular to the plane's slope.
        let expected = simd_normalize(simd_float3(-0.02, 1, 0.01))
        XCTAssertEqual(simd_dot(fit.normal, expected), 1, accuracy: 1e-4)
        // Centroid sits on the plane.
        let residual = 0.02 * fit.point.x - 0.01 * fit.point.z + 0.5 - fit.point.y
        XCTAssertEqual(residual, 0, accuracy: 1e-5)
    }

    func testPlaneFitRejectsTooFewPoints() {
        let few = (0..<5).map { simd_float3(Float($0), 0, 0) }
        XCTAssertNil(ARCardMeasurer.fitHorizontalPlane(few))
    }

    // MARK: - Calibration

    func testCalibrationFactorFromPerfectScanIsIdentity() throws {
        let scan = CardMeasurement(widthMM: 53.98, heightMM: 85.60, confidence: 1)
        let factor = try XCTUnwrap(ScaleCalibration.factor(measured: scan, appliedFactor: 1.0))
        XCTAssertEqual(factor, 1.0, accuracy: 1e-9)
    }

    func testCalibrationFactorCorrectsAUniformScaleError() throws {
        // Device reads 2% large → factor must shrink by 2%.
        let scan = CardMeasurement(widthMM: 53.98 * 1.02, heightMM: 85.60 * 1.02, confidence: 1)
        let factor = try XCTUnwrap(ScaleCalibration.factor(measured: scan, appliedFactor: 1.0))
        XCTAssertEqual(factor, 1 / 1.02, accuracy: 1e-6)
    }

    func testCalibrationComposesOnAnExistingFactor() throws {
        // Already correcting 0.98; the scan (with that correction applied)
        // still reads 1% large → composed factor ≈ 0.98 / 1.01.
        let scan = CardMeasurement(widthMM: 53.98 * 1.01, heightMM: 85.60 * 1.01, confidence: 1)
        let factor = try XCTUnwrap(ScaleCalibration.factor(measured: scan, appliedFactor: 0.98))
        XCTAssertEqual(factor, 0.98 / 1.01, accuracy: 1e-6)
    }

    func testCalibrationRejectsAScanThatIsNotABankCard() {
        // A poker card is nowhere near ISO ID-1 dimensions.
        let scan = CardMeasurement(widthMM: 63.5, heightMM: 88, confidence: 1)
        XCTAssertNil(ScaleCalibration.factor(measured: scan, appliedFactor: 1.0))
    }

    // MARK: - Uncertainty-aware matching

    func testMedianCarriesSampleScatterAsSpread() throws {
        let samples = [63.2, 63.5, 63.6, 63.5, 64.0].map {
            CardMeasurement(widthMM: $0, heightMM: 88, confidence: 1)
        }
        let merged = try XCTUnwrap(ARCardMeasurer.median(of: samples))
        XCTAssertEqual(merged.widthMM, 63.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(merged.spreadMM, 0.3, "floor keeps honesty")
        XCTAssertLessThan(merged.spreadMM, 1.0)
    }

    func testTightMeasurementResolvesToASingleSize() throws {
        let tight = CardMeasurement(widthMM: 63.4, heightMM: 88.1, confidence: 1, spreadMM: 0.3)
        let match = try XCTUnwrap(SleeveMatcher.matchWithAlternative(to: tight, in: makeSizes()))
        XCTAssertEqual(match.best.id, "standard")
        XCTAssertNil(match.alternative, "multi-mm separation is decisive at 0.3mm spread")
    }

    func testUncertainMeasurementSurfacesTheRunnerUp() throws {
        // Halfway between Standard American (57.5×89) and Catan (59×92),
        // scanned with a wobbly hand.
        let wobbly = CardMeasurement(widthMM: 58.2, heightMM: 90.4, confidence: 0.6, spreadMM: 1.6)
        let match = try XCTUnwrap(SleeveMatcher.matchWithAlternative(to: wobbly, in: makeSizes()))
        XCTAssertNotNil(match.alternative, "ambiguity must be surfaced, not guessed away")
    }

    // MARK: - Recommendation margin (+2mm)

    func testRecommendationMarginEnlargesBothEdges() {
        let card = CardMeasurement(widthMM: 61.0, heightMM: 86.0, confidence: 1)
        let padded = SleeveMatcher.withRecommendationMargin(card)
        XCTAssertEqual(padded.widthMM, 63.0, accuracy: 1e-9)
        XCTAssertEqual(padded.heightMM, 88.0, accuracy: 1e-9)
    }

    func testCommonPokerCardStillRecommendsStandard() throws {
        // 63.5×88 + 2mm = 65.5×90; standards are spaced far enough apart that
        // the poker card still lands on Standard, not a neighbour.
        let card = CardMeasurement(widthMM: 63.5, heightMM: 88, confidence: 1)
        let result = try XCTUnwrap(SleeveMatcher.recommended(for: card, in: makeSizes()))
        XCTAssertEqual(result.best.id, "standard")
    }

    func testMarginLeansToTheRoomierSleeveOnACloseCall() throws {
        // A card measured right at Standard American (57.5×89): +2mm pushes the
        // target to 59.5×91, so the roomier Catan (59×92) is now the pick —
        // the intended "give the card a little headroom" behaviour.
        let sizes = [
            makeSize(id: "standard-american", w: 57.5, h: 89),
            makeSize(id: "catan", w: 59, h: 92),
        ]
        let card = CardMeasurement(widthMM: 57.5, heightMM: 89, confidence: 1)
        let result = try XCTUnwrap(SleeveMatcher.recommended(for: card, in: sizes))
        XCTAssertEqual(result.best.id, "catan")
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

    private func makeSize(id: String, w: Double, h: Double) -> SleeveSize {
        SleeveSize(
            id: id, name: id, widthMM: w, heightMM: h,
            tagline: "", blurb: "", examples: [], isCommon: false, sortIndex: 0)
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

    /// Synthetic multi-size game exercising the aggregation math. (Its numbers
    /// once mirrored Wingspan, but real Wingspan cards are all one size —
    /// 57×87mm, corrected in catalog v6 — so this is deliberately fictional.)
    func testDeckTotalsAggregateAcrossSizes() throws {
        let container = try ModelContainer(
            for: Game.self, CardDeck.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let game = Game(id: "multi", title: "Multi-Size Game", publisher: "", year: 2020)
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
