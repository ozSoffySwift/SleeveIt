import ARKit
import Combine
import CoreImage
import UIKit
import Vision
import simd
import os

private let measureLogger = Logger(subsystem: "com.sleeveit.SleeveIt", category: "measure")

/// Shared context for cropping card snapshots; CIContext is expensive to create
/// and thread-safe to reuse.
private let snapshotContext = CIContext()

/// Drives the AR session and turns camera frames into real-world card dimensions.
///
/// The approach: Vision finds the card's quadrilateral in the camera image; the
/// card's plane is anchored in world space (LiDAR depth on devices that have it,
/// raycast otherwise); and each corner's camera ray is intersected with that
/// plane. That yields four coplanar points in metres, and the edge lengths
/// between them are the card's true physical size. Vision alone could only give
/// pixels; ARKit alone could only measure where the user aimed. Together they
/// measure the card the user actually placed down.
///
/// Works on any ARKit-capable device. On LiDAR devices (iPhone Pro models) the
/// plane distance comes straight from the depth sensor, which is what the
/// measurement's absolute scale hangs on.
@MainActor
final class ARCardMeasurer: NSObject, ObservableObject {

    enum Phase: Equatable {
        /// Looking for a flat surface to anchor against.
        case findingSurface
        /// Surface found, scanning for a card.
        case searching
        /// A card is detected and being measured; carries the live readout.
        case detecting(CardMeasurement)
        /// A stable measurement has settled.
        case locked(CardMeasurement)
        /// Detection failed or was lost for long enough to warrant guidance.
        case failed(Reason)

        enum Reason: Equatable {
            case unsupportedDevice
            case cameraDenied
            case lostCard
        }
    }

    /// One processed frame's outcome: the physical size plus where the card sits
    /// on screen, so the UI can draw its frame on the card rather than centred.
    struct DetectionResult {
        var measurement: CardMeasurement
        /// TL, TR, BR, BL in view points. Empty until the viewport size is known.
        var viewQuad: [CGPoint]
        /// A crop of the card from this frame, captured only while the lock
        /// countdown runs, so the locked screen can present the card itself.
        var cardImage: CGImage?
    }

    @Published private(set) var phase: Phase = .findingSurface
    /// The detected card's corners in view coordinates, for drawing the scan
    /// frame on the card itself. Retains its last value after a lock so the
    /// locked overlay stays on the card.
    @Published private(set) var cardQuad: [CGPoint]?
    /// A sharp crop of the measured card from the confirming second, shown
    /// centred with a border on the locked screen.
    @Published private(set) var lockedCardImage: UIImage?
    @Published var isTorchOn = false

    /// A settled measurement must hold steady for this long before locking.
    /// Locking on the first stable window froze whatever frame happened to be
    /// current — often blurred mid-focus; a full second forces a genuinely
    /// steady hand and gives autofocus time to land, so the final frame and the
    /// card snapshot are sharp.
    private let lockConfirmation: TimeInterval = 1.0

    /// During the countdown, frames only need to agree with the candidate
    /// within this much per edge. Requiring the full stability window to keep
    /// passing on every frame meant one micro-jitter restarted the countdown —
    /// which is why locks almost never completed handheld.
    private let confirmToleranceMM: Double = 3.0

    /// Vision can briefly lose the card mid-countdown (glare, a finger edge);
    /// tolerate a few missed frames before abandoning the lock attempt.
    private let confirmMissGrace = 5

    private var settledSince: Date?
    private var lockCandidate: CardMeasurement?
    private var confirmSamples: [CardMeasurement] = []
    private var confirmMisses = 0
    private var candidateSnapshot: CGImage?

    let session = ARSession()

    private var stabilizer = MeasurementStabilizer()
    private var lastDetectionAt: Date?
    private var hasPlane = false
    private var startedAt: Date?

    /// Frames without a card before we surface the error sheet.
    private let lostCardGrace: TimeInterval = 6

    /// Vision runs here, off the main thread. Frames that arrive while one is
    /// being processed are DROPPED, never queued — queued work retains ARFrames,
    /// and ARKit throttles its camera pipeline when frames are held back.
    nonisolated private let visionQueue = DispatchQueue(
        label: "com.sleeveit.SleeveIt.vision", qos: .userInitiated)
    nonisolated private let frameGate = OSAllocatedUnfairLock(initialState: false)
    nonisolated private let isMeasuring = OSAllocatedUnfairLock(initialState: false)
    /// The on-screen size the camera renders into, needed to map detected
    /// corners into view coordinates. Fed by the view via `setViewport`.
    nonisolated private let viewportStore = OSAllocatedUnfairLock(initialState: CGSize.zero)
    /// True only during the lock countdown, so card snapshots are cropped just
    /// for the handful of frames that might become the locked image.
    nonisolated private let wantSnapshot = OSAllocatedUnfairLock(initialState: false)

    /// The view calls this with the full-screen size the camera fills.
    func setViewport(_ size: CGSize) {
        viewportStore.withLock { $0 = size }
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    override init() {
        super.init()
        session.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard Self.isSupported else {
            phase = .failed(.unsupportedDevice)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            phase = .failed(.cameraDenied)
            return
        }

        stabilizer.reset()
        hasPlane = false
        lastDetectionAt = nil
        startedAt = .now
        cardQuad = nil
        lockedCardImage = nil
        cancelLockCountdown()
        phase = .findingSurface
        isMeasuring.withLock { $0 = true }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        // On LiDAR devices, per-pixel depth anchors the card's plane at the
        // sensor-measured distance instead of a raycast estimate. The whole
        // measurement scales with that distance, so this is the single biggest
        // accuracy lever. Smoothed variant: temporally filtered, less jitter.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        isMeasuring.withLock { $0 = false }
        session.pause()
        setTorch(on: false)
    }

    /// Restarts detection after an error, without tearing down the session.
    func retry() {
        stabilizer.reset()
        lastDetectionAt = nil
        startedAt = .now
        cardQuad = nil
        lockedCardImage = nil
        cancelLockCountdown()
        isMeasuring.withLock { $0 = true }
        phase = hasPlane ? .searching : .findingSurface
    }

    // MARK: - Torch

    func toggleTorch() {
        setTorch(on: !isTorchOn)
    }

    private func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = on
        } catch {
            measureLogger.error("Torch unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: - Ingest (main actor)

    /// Takes one processed frame's outcome and advances the state machine.
    ///
    /// Two stages: **acquire** (the stabilizer finds a steady candidate), then
    /// **confirm** (hold for `lockConfirmation`, during which frames only need
    /// to agree with the candidate within `confirmToleranceMM`). The final lock
    /// is the median of every confirming sample.
    private func ingest(_ result: DetectionResult?) {
        if case .locked = phase { return }

        guard let result else {
            // Tolerate brief detection dropouts mid-countdown rather than
            // abandoning an almost-complete lock.
            if lockCandidate != nil, confirmMisses < confirmMissGrace {
                confirmMisses += 1
                return
            }
            noteMissingCard()
            return
        }

        lastDetectionAt = .now
        confirmMisses = 0
        if result.viewQuad.count == 4 {
            cardQuad = result.viewQuad
        }
        if let image = result.cardImage {
            candidateSnapshot = image
        }

        let measurement = result.measurement.normalized

        // --- Confirm stage ---
        if let candidate = lockCandidate, let since = settledSince {
            let agrees = abs(measurement.widthMM - candidate.widthMM) <= confirmToleranceMM
                && abs(measurement.heightMM - candidate.heightMM) <= confirmToleranceMM

            guard agrees else {
                // The reading genuinely jumped — start acquisition over.
                cancelLockCountdown()
                stabilizer.reset()
                _ = stabilizer.accept(result.measurement)
                phase = .detecting(measurement)
                return
            }

            confirmSamples.append(measurement)

            if Date.now.timeIntervalSince(since) >= lockConfirmation {
                let final = Self.median(of: confirmSamples) ?? candidate
                if let snapshot = candidateSnapshot {
                    lockedCardImage = UIImage(cgImage: snapshot)
                }
                phase = .locked(final)
                stop()
            } else {
                phase = .detecting(measurement)
            }
            return
        }

        // --- Acquire stage ---
        if let settled = stabilizer.accept(result.measurement) {
            lockCandidate = settled
            settledSince = .now
            confirmSamples = [settled]
            wantSnapshot.withLock { $0 = true }
            phase = .detecting(settled.normalized)
        } else {
            phase = .detecting(measurement)
        }
    }

    /// Per-dimension median — robust to the odd outlier in the confirm window.
    nonisolated static func median(of samples: [CardMeasurement]) -> CardMeasurement? {
        guard !samples.isEmpty else { return nil }
        let width = samples.map(\.widthMM).sorted()[samples.count / 2]
        let height = samples.map(\.heightMM).sorted()[samples.count / 2]
        let confidence = samples.map(\.confidence).max() ?? 0.5
        return CardMeasurement(widthMM: width, heightMM: height, confidence: confidence)
    }

    private func cancelLockCountdown() {
        settledSince = nil
        lockCandidate = nil
        confirmSamples = []
        confirmMisses = 0
        candidateSnapshot = nil
        wantSnapshot.withLock { $0 = false }
    }

    private func noteMissingCard() {
        stabilizer.reset()
        cardQuad = nil
        cancelLockCountdown()

        guard let since = lastDetectionAt ?? startedAt else { return }
        if Date.now.timeIntervalSince(since) > lostCardGrace {
            if case .failed = phase { return }
            phase = .failed(.lostCard)
        } else if hasPlane, case .findingSurface = phase {
            phase = .searching
        } else if case .detecting = phase {
            phase = .searching
        }
    }

    // MARK: - Detection (background)

    /// Runs Vision on one frame and measures the best rectangle, if any.
    nonisolated static func measureCard(
        in frame: ARFrame, session: ARSession, viewport: CGSize, includeSnapshot: Bool
    ) -> DetectionResult? {
        let request = VNDetectRectanglesRequest()
        // Playing cards run roughly 0.55–0.75 shorter/longer edge; allow slack
        // for perspective. Vision's aspect is orientation-neutral, so sideways
        // cards pass too.
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.95
        request.minimumSize = 0.12
        request.minimumConfidence = 0.6
        request.maximumObservations = 5
        request.quadratureTolerance = 20

        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.capturedImage,
            orientation: .right,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            measureLogger.error("Vision failed: \(error.localizedDescription)")
            return nil
        }

        let observations = request.results ?? []
        let candidates = observations.map { obs in
            RectCandidate(
                confidence: obs.confidence,
                area: quadArea(of: [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]),
                center: CGPoint(
                    x: (obs.topLeft.x + obs.topRight.x + obs.bottomRight.x + obs.bottomLeft.x) / 4,
                    y: (obs.topLeft.y + obs.topRight.y + obs.bottomRight.y + obs.bottomLeft.y) / 4
                )
            )
        }
        guard let bestIndex = bestCandidateIndex(candidates) else { return nil }
        return measure(
            observation: observations[bestIndex],
            frame: frame, session: session, viewport: viewport, includeSnapshot: includeSnapshot)
    }

    /// A rectangle candidate reduced to what selection needs — pure data, so the
    /// picking rule is unit-testable without constructing Vision observations.
    struct RectCandidate {
        var confidence: Float
        var area: Double
        var center: CGPoint
    }

    /// Picks which detected rectangle is *the card*.
    ///
    /// Confidence alone is a trap: many cards print an inner frame around the
    /// art, Vision reports both rectangles, and the inner one often scores
    /// higher — silently shrinking the measurement. Area breaks that tie in
    /// favour of the physical card edge. And between separate objects, the one
    /// nearest the image centre wins: it's the one the user is aiming at, not
    /// the notebook beside it.
    nonisolated static func bestCandidateIndex(_ candidates: [RectCandidate]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let imageCenter = CGPoint(x: 0.5, y: 0.5)
        // Concentric rectangles (within 8% of each other's centre) collapse to
        // the largest — the card's outer edge, not its printed inner frame.
        let aimed = candidates.indices.filter { i in
            let c = candidates[i].center
            return hypot(c.x - imageCenter.x, c.y - imageCenter.y) < 0.25
        }
        let pool = aimed.isEmpty ? Array(candidates.indices) : aimed
        return pool.max { candidates[$0].area < candidates[$1].area }
    }

    /// Shoelace area of a normalized quad. Pure; used to prefer the card's
    /// outer edge over any concentric inner frame.
    nonisolated static func quadArea(of corners: [CGPoint]) -> Double {
        guard corners.count >= 3 else { return 0 }
        var sum = 0.0
        for i in corners.indices {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Measures the observed rectangle against the surface it's resting on.
    ///
    /// **One plane, four analytic intersections.** Raycasting each corner
    /// independently lets ARKit resolve each to a slightly different estimated
    /// depth, which warps the quad and skews the size. Instead the card's plane
    /// is established once — a single raycast through the quad's centre,
    /// preferring real detected plane geometry — and each corner's camera ray
    /// (from the camera intrinsics) is intersected with that plane. The corners
    /// are coplanar by construction, so edge lengths are consistent.
    nonisolated private static func measure(
        observation: VNRectangleObservation,
        frame: ARFrame,
        session: ARSession,
        viewport: CGSize,
        includeSnapshot: Bool
    ) -> DetectionResult? {
        let corners = [
            observation.topLeft,
            observation.topRight,
            observation.bottomRight,
            observation.bottomLeft,
        ]

        // 1. The card's plane. The anchor *point* sets the measurement's scale,
        // so its priority order is: LiDAR depth at the quad's centre (a direct
        // time-of-flight distance), then a raycast against detected plane
        // geometry, then an estimated plane. The raycast still supplies the
        // plane's *orientation* when it hits; failing that, gravity alignment
        // makes straight-up the honest normal for a horizontal table.
        let center = CGPoint(
            x: corners.map(\.x).reduce(0, +) / 4,
            y: corners.map(\.y).reduce(0, +) / 4
        )
        let sensorCenter = sensorPoint(fromVisionPoint: center)
        var planeHit = session.raycast(frame.raycastQuery(
            from: sensorCenter, allowing: .existingPlaneGeometry, alignment: .horizontal)).first
        if planeHit == nil {
            planeHit = session.raycast(frame.raycastQuery(
                from: sensorCenter, allowing: .estimatedPlane, alignment: .horizontal)).first
        }
        let depthPoint = depthAnchoredPoint(frame: frame, sensorPoint: sensorCenter)

        let planePoint: simd_float3
        if let depthPoint {
            planePoint = depthPoint
        } else if let planeHit {
            planePoint = simd_make_float3(planeHit.worldTransform.columns.3)
        } else {
            return nil
        }

        var planeNormal = simd_float3(0, 1, 0)
        if let planeHit {
            let rawNormal = simd_make_float3(planeHit.worldTransform.columns.1)
            if simd_length(rawNormal) > 0.5 {
                planeNormal = simd_normalize(rawNormal)
            }
        }

        // 2. Each corner's camera ray, intersected with that plane.
        let camera = frame.camera
        let cameraTransform = camera.transform
        let rayOrigin = simd_make_float3(cameraTransform.columns.3)
        let intrinsics = camera.intrinsics
        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))

        let sensorCorners = corners.map { sensorPoint(fromVisionPoint: $0) }
        let points = sensorCorners.compactMap { sensor -> simd_float3? in
            let directionCamera = cameraRayDirection(
                pixelX: Float(sensor.x) * imageWidth,
                pixelY: Float(sensor.y) * imageHeight,
                fx: intrinsics[0][0], fy: intrinsics[1][1],
                ox: intrinsics[2][0], oy: intrinsics[2][1]
            )
            let world4 = cameraTransform * simd_float4(directionCamera, 0)
            let direction = simd_normalize(simd_make_float3(world4))
            return intersect(
                rayOrigin: rayOrigin, rayDirection: direction,
                planePoint: planePoint, planeNormal: planeNormal
            )
        }
        guard points.count == 4 else { return nil }

        // Opposite edges are averaged so a slight perspective skew doesn't bias
        // the result toward whichever edge is nearer the camera.
        let top = simd_distance(points[0], points[1])
        let bottom = simd_distance(points[3], points[2])
        let left = simd_distance(points[0], points[3])
        let right = simd_distance(points[1], points[2])

        let widthMM = Double((top + bottom) / 2) * 1000
        let heightMM = Double((left + right) / 2) * 1000

        // Reject nonsense early — a raycast that hit the floor instead of the
        // table produces implausibly large values.
        let plausible = 20.0...200.0
        guard plausible.contains(widthMM), plausible.contains(heightMM) else { return nil }

        // Opposite edges disagreeing badly means the quad isn't planar with the
        // surface — usually a mis-detection on a patterned background.
        let widthSkew = abs(Double(top - bottom)) * 1000
        let heightSkew = abs(Double(left - right)) * 1000
        guard widthSkew < 6, heightSkew < 6 else { return nil }

        // 3. The card's on-screen quad, so the UI can draw its frame on the
        // card. displayTransform maps sensor-space normalized points into the
        // viewport exactly as ARKit renders the camera image (aspect-filled).
        var viewQuad: [CGPoint] = []
        if viewport.width > 1, viewport.height > 1 {
            let transform = frame.displayTransform(for: .portrait, viewportSize: viewport)
            viewQuad = corners.map { corner in
                let normalized = sensorPoint(fromVisionPoint: corner).applying(transform)
                return CGPoint(x: normalized.x * viewport.width, y: normalized.y * viewport.height)
            }
        }

        let measurement = CardMeasurement(
            widthMM: widthMM, heightMM: heightMM, confidence: Double(observation.confidence))
        let snapshot = includeSnapshot
            ? cropCardImage(from: frame, sensorCorners: sensorCorners)
            : nil
        return DetectionResult(measurement: measurement, viewQuad: viewQuad, cardImage: snapshot)
    }

    /// Crops the card (plus a small margin) out of the captured frame and
    /// rotates it upright, for the locked screen's centred presentation.
    nonisolated private static func cropCardImage(
        from frame: ARFrame, sensorCorners: [CGPoint]
    ) -> CGImage? {
        let buffer = frame.capturedImage
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))

        let xs = sensorCorners.map { $0.x * width }
        let ys = sensorCorners.map { $0.y * height }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        let marginX = (maxX - minX) * 0.08
        let marginY = (maxY - minY) * 0.08
        // Sensor points are top-left origin; CIImage is bottom-left — flip y.
        let cropRect = CGRect(
            x: minX - marginX,
            y: height - (maxY + marginY),
            width: (maxX - minX) + marginX * 2,
            height: (maxY - minY) + marginY * 2
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !cropRect.isEmpty else { return nil }

        let cropped = CIImage(cvPixelBuffer: buffer)
            .cropped(to: cropRect)
            .oriented(.right)
        return snapshotContext.createCGImage(cropped, from: cropped.extent)
    }

    // MARK: - Geometry primitives

    /// The camera-space ray through a pixel of the captured image.
    ///
    /// ARKit's camera space is +x right, +y up, looking down −z; image pixels
    /// run +x right, +y **down** — hence the y flip.
    nonisolated static func cameraRayDirection(
        pixelX: Float, pixelY: Float,
        fx: Float, fy: Float, ox: Float, oy: Float
    ) -> simd_float3 {
        simd_normalize(simd_float3((pixelX - ox) / fx, -(pixelY - oy) / fy, -1))
    }

    /// Unprojects a captured-image pixel with a known depth into ARKit camera
    /// space.
    ///
    /// `depth` follows ARDepthData semantics: metres along the camera's optical
    /// axis (z-depth), *not* Euclidean distance along the ray — so the result's
    /// camera-space z is exactly `-depth`. Same axis convention as
    /// `cameraRayDirection`: +x right, +y up, looking down −z.
    nonisolated static func cameraPoint(
        pixelX: Float, pixelY: Float, depth: Float,
        fx: Float, fy: Float, ox: Float, oy: Float
    ) -> simd_float3 {
        simd_float3((pixelX - ox) / fx * depth, -(pixelY - oy) / fy * depth, -depth)
    }

    /// Reads LiDAR depth at a sensor-normalized point and returns the world
    /// point on the surface there, or nil when depth is absent or untrusted.
    ///
    /// The measurement's scale is set entirely by how far away the card's
    /// plane is, so anchoring it with a direct time-of-flight distance beats
    /// any raycast estimate. The depth map is coarse (256×192) — a 3×3 median
    /// rides out single-texel noise — and the confidence map gates out what
    /// the sensor itself distrusts (notably under ~25 cm, LiDAR's minimum
    /// range, where the raycast fallback takes over).
    nonisolated private static func depthAnchoredPoint(
        frame: ARFrame, sensorPoint: CGPoint
    ) -> simd_float3? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let px = min(max(Int(sensorPoint.x * CGFloat(width)), 0), width - 1)
        let py = min(max(Int(sensorPoint.y * CGFloat(height)), 0), height - 1)

        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(confidenceMap) {
                let rowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
                let level = base.advanced(by: py * rowBytes + px)
                    .assumingMemoryBound(to: UInt8.self).pointee
                guard level >= UInt8(ARConfidenceLevel.medium.rawValue) else { return nil }
            }
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var samples: [Float] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let x = px + dx, y = py + dy
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let value = base.advanced(by: y * rowBytes + x * MemoryLayout<Float32>.stride)
                    .assumingMemoryBound(to: Float32.self).pointee
                if value.isFinite, value > 0.1, value < 2.0 { samples.append(value) }
            }
        }
        // A patch straddling a depth discontinuity (table edge) yields few
        // valid samples — better no anchor than a wrong one.
        guard samples.count >= 5 else { return nil }
        let depth = samples.sorted()[samples.count / 2]

        let intrinsics = frame.camera.intrinsics
        let local = cameraPoint(
            pixelX: Float(sensorPoint.x) * Float(CVPixelBufferGetWidth(frame.capturedImage)),
            pixelY: Float(sensorPoint.y) * Float(CVPixelBufferGetHeight(frame.capturedImage)),
            depth: depth,
            fx: intrinsics[0][0], fy: intrinsics[1][1],
            ox: intrinsics[2][0], oy: intrinsics[2][1]
        )
        let world = frame.camera.transform * simd_float4(local, 1)
        return simd_make_float3(world)
    }

    /// Ray–plane intersection; nil when the ray is parallel to or points away
    /// from the plane.
    nonisolated static func intersect(
        rayOrigin: simd_float3, rayDirection: simd_float3,
        planePoint: simd_float3, planeNormal: simd_float3
    ) -> simd_float3? {
        let denominator = simd_dot(rayDirection, planeNormal)
        guard abs(denominator) > 1e-5 else { return nil }
        let t = simd_dot(planePoint - rayOrigin, planeNormal) / denominator
        guard t > 0 else { return nil }
        return rayOrigin + t * rayDirection
    }

    /// Converts a Vision point into ARKit's captured-image space.
    ///
    /// Vision was run against the frame oriented `.right` (portrait), and its
    /// points are normalized with a bottom-left origin. `raycastQuery(from:)`
    /// wants normalized points in the *sensor-native landscape* image with a
    /// top-left origin. Portrait is the sensor image rotated 90° clockwise, so
    /// the inverse mapping is (x, y) → (1 − y, 1 − x).
    ///
    /// Getting this wrong doesn't degrade the measurement — it destroys it:
    /// every raycast lands 90° away from the card, and no sample ever survives
    /// the sanity checks, so the scan never locks.
    nonisolated static func sensorPoint(fromVisionPoint point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.y, y: 1 - point.x)
    }
}

// MARK: - ARSessionDelegate

extension ARCardMeasurer: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isMeasuring.withLock({ $0 }) else { return }

        // Claim the single in-flight slot or drop the frame — dropping keeps
        // ARKit's pipeline flowing; queueing would retain frames and stall it.
        let claimed = frameGate.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard claimed else { return }

        let viewport = viewportStore.withLock { $0 }
        let includeSnapshot = wantSnapshot.withLock { $0 }
        visionQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.measureCard(
                in: frame, session: session, viewport: viewport, includeSnapshot: includeSnapshot)
            self.frameGate.withLock { $0 = false }
            Task { @MainActor [weak self] in
                self?.ingest(result)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard anchors.contains(where: { $0 is ARPlaneAnchor }) else { return }
        Task { @MainActor in
            self.hasPlane = true
            if case .findingSurface = self.phase {
                self.phase = .searching
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            measureLogger.error("AR session failed: \(error.localizedDescription)")
            self.phase = .failed(.lostCard)
        }
    }
}
