import ARKit
import Combine
import Vision
import simd
import os

/// Drives the AR session and turns camera frames into real-world card dimensions.
///
/// The approach: Vision finds the card's quadrilateral in the camera image, then
/// ARKit raycasts each of those four corners onto the detected table plane. That
/// yields four points in metres in world space, and the edge lengths between them
/// are the card's true physical size. Vision alone could only give pixels; ARKit
/// alone could only measure where the user aimed. Together they measure the card
/// the user actually placed down.
///
/// Works on any ARKit-capable device. LiDAR improves plane depth accuracy but is
/// not required.
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

    @Published private(set) var phase: Phase = .findingSurface
    @Published var isTorchOn = false

    let session = ARSession()

    private let logger = Logger(subsystem: "com.sleeveit.SleeveIt", category: "measure")
    private var stabilizer = MeasurementStabilizer()
    private var isProcessingFrame = false
    private var lastDetectionAt: Date?
    private var hasPlane = false
    private var startedAt: Date?

    /// Frames without a card before we surface the error sheet.
    private let lostCardGrace: TimeInterval = 6

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
        phase = .findingSurface

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        setTorch(on: false)
    }

    /// Restarts detection after an error, without tearing down the session.
    func retry() {
        stabilizer.reset()
        lastDetectionAt = nil
        startedAt = .now
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
            logger.error("Torch unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: - Frame processing

    fileprivate func process(frame: ARFrame) {
        guard !isProcessingFrame else { return }
        guard case .locked = phase else {
            isProcessingFrame = true
            detectCard(in: frame)
            return
        }
    }

    private func detectCard(in frame: ARFrame) {
        let request = VNDetectRectanglesRequest { [weak self] request, error in
            Task { @MainActor in
                defer { self?.isProcessingFrame = false }
                guard let self else { return }
                if let error {
                    self.logger.error("Vision failed: \(error.localizedDescription)")
                    return
                }
                let observations = (request.results as? [VNRectangleObservation]) ?? []
                self.handle(observations: observations, frame: frame)
            }
        }

        // Playing cards run roughly 0.55–0.75 aspect; allow slack for perspective.
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.95
        request.minimumSize = 0.15
        request.minimumConfidence = 0.7
        request.maximumObservations = 3
        request.quadratureTolerance = 20

        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.capturedImage,
            orientation: .right,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            isProcessingFrame = false
            logger.error("Vision handler failed: \(error.localizedDescription)")
        }
    }

    private func handle(observations: [VNRectangleObservation], frame: ARFrame) {
        guard let best = observations.max(by: { $0.confidence < $1.confidence }) else {
            noteMissingCard()
            return
        }
        guard let measurement = measure(observation: best, frame: frame) else {
            noteMissingCard()
            return
        }

        lastDetectionAt = .now

        if let settled = stabilizer.accept(measurement) {
            phase = .locked(settled)
            stop()
        } else {
            phase = .detecting(measurement.normalized)
        }
    }

    /// Projects the observed rectangle's corners onto the AR plane and measures
    /// the resulting quad in world space.
    private func measure(observation: VNRectangleObservation, frame: ARFrame) -> CardMeasurement? {
        let corners = [
            observation.topLeft,
            observation.topRight,
            observation.bottomRight,
            observation.bottomLeft,
        ]

        let points = corners.compactMap { worldPoint(forNormalizedImagePoint: $0, frame: frame) }
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
        guard widthSkew < 4, heightSkew < 4 else { return nil }

        return CardMeasurement(widthMM: widthMM, heightMM: heightMM, confidence: Double(observation.confidence))
    }

    /// Raycasts one normalised Vision point onto the nearest horizontal plane.
    private func worldPoint(forNormalizedImagePoint point: CGPoint, frame: ARFrame) -> simd_float3? {
        // Vision's origin is bottom-left; ARKit's viewport mapping expects top-left.
        let flipped = CGPoint(x: point.x, y: 1 - point.y)

        let query = frame.raycastQuery(
            from: flipped,
            allowing: .estimatedPlane,
            alignment: .horizontal
        )

        guard let result = session.raycast(query).first else { return nil }
        return simd_make_float3(result.worldTransform.columns.3)
    }

    private func noteMissingCard() {
        stabilizer.reset()

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
}

// MARK: - ARSessionDelegate

extension ARCardMeasurer: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            self.process(frame: frame)
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
            self.logger.error("AR session failed: \(error.localizedDescription)")
            self.phase = .failed(.lostCard)
        }
    }
}
