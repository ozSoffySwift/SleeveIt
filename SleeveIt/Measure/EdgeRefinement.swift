import CoreVideo
import Foundation

/// Refines a detected card quad to sub-pixel precision.
///
/// Vision's rectangle corners are whole-pixel and often sit a few pixels off
/// the true edge — at typical scan distance each pixel is ~0.2mm, so that
/// error alone can push a card into the wrong sleeve class. The fix is the
/// classic document-scanner move: don't trust four corners, trust four
/// *edges*. Along each side of the coarse quad, sample the luma gradient at
/// dozens of points, keep the sub-pixel gradient peak at each, robust-fit a
/// line per side, and intersect the lines. Hundreds of measurements collapse
/// into four corners good to a fraction of a pixel.
enum EdgeRefinement {

    /// How far (px) either side of the coarse edge to search for the gradient peak.
    static let searchRadius: Double = 8
    /// Sample points along each edge (excluding the corner regions, which curve).
    static let samplesPerEdge = 24
    /// A refined corner farther than this from its coarse start is a failed
    /// refinement (glare, occlusion) — the coarse quad is kept instead.
    static let maxCornerShift: Double = 8

    // MARK: - Public entry

    /// Refines 4 corners (TL, TR, BR, BL in pixel space) against the luma
    /// plane of a captured frame. Returns the input unchanged when refinement
    /// can't improve on it — never worse than Vision's own quad.
    static func refine(corners: [CGPoint], luma: LumaPlane) -> [CGPoint] {
        guard corners.count == 4 else { return corners }

        var lines: [Line] = []
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            guard let line = refineEdge(from: a, to: b, luma: luma) else { return corners }
            lines.append(line)
        }

        var refined: [CGPoint] = []
        for i in 0..<4 {
            // Corner i is the meet of the edge arriving at it and the edge leaving it.
            let incoming = lines[(i + 3) % 4]
            let outgoing = lines[i]
            guard let p = intersection(incoming, outgoing),
                  hypot(p.x - corners[i].x, p.y - corners[i].y) <= maxCornerShift
            else { return corners }
            refined.append(p)
        }
        return refined
    }

    // MARK: - Edge line from gradient peaks

    private static func refineEdge(from a: CGPoint, to b: CGPoint, luma: LumaPlane) -> Line? {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 20 else { return nil }
        // Unit normal to the edge; gradient is sampled along this direction.
        let nx = -dy / length, ny = dx / length

        var points: [CGPoint] = []
        // Skip 12% at each end — corners are rounded on real cards.
        for s in 0..<samplesPerEdge {
            let t = 0.12 + 0.76 * Double(s) / Double(samplesPerEdge - 1)
            let cx = a.x + dx * t
            let cy = a.y + dy * t
            if let offset = gradientPeak(
                atX: cx, y: cy, normalX: nx, normalY: ny, luma: luma
            ) {
                points.append(CGPoint(x: cx + nx * offset, y: cy + ny * offset))
            }
        }
        // Refinement needs a healthy majority of samples to trust the fit.
        guard points.count >= samplesPerEdge * 6 / 10 else { return nil }

        guard let first = fitLine(points) else { return nil }
        // One outlier-rejection pass: drop points far off the fitted line, refit.
        let residuals = points.map { distance(from: $0, to: first) }
        let threshold = max(1.0, 2.5 * (residuals.reduce(0, +) / Double(residuals.count)))
        let inliers = zip(points, residuals).filter { $0.1 <= threshold }.map(\.0)
        guard inliers.count >= points.count * 6 / 10 else { return first }
        return fitLine(inliers) ?? first
    }

    /// Finds the sub-pixel offset along the normal where the luma gradient
    /// magnitude peaks — the physical card edge.
    private static func gradientPeak(
        atX x: Double, y: Double, normalX nx: Double, normalY ny: Double, luma: LumaPlane
    ) -> Double? {
        let step = 0.5
        let count = Int(searchRadius * 2 / step) + 1
        var magnitudes = [Double](repeating: 0, count: count)
        var bestIndex = -1
        var bestMagnitude = 0.0

        for i in 0..<count {
            let offset = -searchRadius + Double(i) * step
            // Central difference along the normal.
            let ahead = luma.sample(x: x + nx * (offset + 1), y: y + ny * (offset + 1))
            let behind = luma.sample(x: x + nx * (offset - 1), y: y + ny * (offset - 1))
            guard let ahead, let behind else { continue }
            let magnitude = abs(ahead - behind)
            magnitudes[i] = magnitude
            if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                bestIndex = i
            }
        }
        // A real edge has meaningful contrast; a flat region does not.
        guard bestIndex > 0, bestIndex < count - 1, bestMagnitude > 8 else { return nil }

        let vertex = parabolicPeak(
            magnitudes[bestIndex - 1], magnitudes[bestIndex], magnitudes[bestIndex + 1])
        return -searchRadius + (Double(bestIndex) + vertex) * step
    }

    // MARK: - Pure geometry (unit-tested)

    /// A 2D line in point + unit-direction form.
    struct Line: Equatable {
        var point: CGPoint
        var direction: CGVector  // unit length
    }

    /// Total-least-squares line through points: principal axis of the
    /// covariance, so steep edges fit as well as shallow ones.
    static func fitLine(_ points: [CGPoint]) -> Line? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let mx = points.map(\.x).reduce(0, +) / n
        let my = points.map(\.y).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            let dx = p.x - mx, dy = p.y - my
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        // Principal-axis angle of the 2×2 covariance matrix.
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        return Line(
            point: CGPoint(x: mx, y: my),
            direction: CGVector(dx: cos(theta), dy: sin(theta)))
    }

    /// Where two lines cross; nil when near-parallel.
    static func intersection(_ a: Line, _ b: Line) -> CGPoint? {
        let cross = a.direction.dx * b.direction.dy - a.direction.dy * b.direction.dx
        guard abs(cross) > 1e-9 else { return nil }
        let dx = b.point.x - a.point.x
        let dy = b.point.y - a.point.y
        let t = (dx * b.direction.dy - dy * b.direction.dx) / cross
        return CGPoint(
            x: a.point.x + a.direction.dx * t,
            y: a.point.y + a.direction.dy * t)
    }

    /// Perpendicular distance from a point to a line.
    static func distance(from p: CGPoint, to line: Line) -> Double {
        let dx = p.x - line.point.x
        let dy = p.y - line.point.y
        return abs(dx * line.direction.dy - dy * line.direction.dx)
    }

    /// Sub-sample peak offset in [-0.5, 0.5] from three consecutive samples,
    /// by fitting a parabola through them. 0 when the peak is flat.
    static func parabolicPeak(_ left: Double, _ centre: Double, _ right: Double) -> Double {
        let denominator = left - 2 * centre + right
        guard abs(denominator) > 1e-9 else { return 0 }
        let vertex = 0.5 * (left - right) / denominator
        return min(0.5, max(-0.5, vertex))
    }
}

/// Read-only bilinear access to the luma (Y) plane of a captured frame.
///
/// ARKit frames are 420f bi-planar; plane 0 is full-resolution 8-bit luma —
/// exactly what edge gradients need, with no colour conversion.
struct LumaPlane {
    private let base: UnsafeRawPointer
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    /// The buffer must remain locked (read-only) for this value's lifetime;
    /// callers lock, use, and unlock within one scope.
    init?(lockedBuffer buffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            let address = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        else { return nil }
        base = UnsafeRawPointer(address)
        width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    }

    /// Bilinear luma at a fractional pixel position; nil outside the image.
    func sample(x: Double, y: Double) -> Double? {
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return nil }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Double(x0), fy = y - Double(y0)
        let row0 = base.advanced(by: y0 * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        let row1 = base.advanced(by: (y0 + 1) * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        let top = Double(row0[x0]) * (1 - fx) + Double(row0[x0 + 1]) * fx
        let bottom = Double(row1[x0]) * (1 - fx) + Double(row1[x0 + 1]) * fx
        return top * (1 - fy) + bottom * fy
    }
}
