import CoreGraphics
import Foundation

/// Derives a card's real size from a photo, using a reference object of known
/// real-world length to set the scale.
///
/// The user marks the card's four corners and a two-point segment across
/// something of known size (a coin's diameter, or a card of known length). The
/// ratio of that segment's known millimetres to its on-screen length gives
/// mm-per-point, which converts the card's edge lengths to millimetres.
///
/// This is the non-AR path — for devices without ARKit, or poor lighting where
/// plane detection fails. It assumes the card and the reference are roughly
/// coplanar and the photo is taken roughly straight-on; it does **not** correct
/// perspective, so it's less accurate than AR but usable where AR isn't.
enum ReferenceMeasurer {

    /// Common reference objects and their real diameters/lengths in mm.
    enum Reference: String, CaseIterable, Identifiable {
        case usQuarter        // 24.26 mm
        case usPenny          // 19.05 mm
        case euro1            // 23.25 mm (1 euro coin)
        case creditCard       // 85.6 mm long edge (ISO/IEC 7810 ID-1)
        case standardCardLong // a poker card's 88 mm long edge

        var id: String { rawValue }

        var lengthMM: Double {
            switch self {
            case .usQuarter: 24.26
            case .usPenny: 19.05
            case .euro1: 23.25
            case .creditCard: 85.6
            case .standardCardLong: 88.0
            }
        }

        var label: String {
            switch self {
            case .usQuarter: "US quarter (24.3 mm)"
            case .usPenny: "US penny (19.1 mm)"
            case .euro1: "€1 coin (23.3 mm)"
            case .creditCard: "Credit card edge (85.6 mm)"
            case .standardCardLong: "Poker card long edge (88 mm)"
            }
        }

        var isCoin: Bool {
            self == .usQuarter || self == .usPenny || self == .euro1
        }
    }

    /// Computes the card measurement.
    ///
    /// - Parameters:
    ///   - cardCorners: the four card corners in point space, any order that
    ///     forms the quad (top-left, top-right, bottom-right, bottom-left).
    ///   - referenceEndpoints: the two marked points across the reference.
    ///   - reference: which object was marked.
    /// - Returns: a normalised `CardMeasurement`, or nil if the inputs are
    ///   degenerate (reference length of zero, fewer than four corners).
    static func measure(
        cardCorners: [CGPoint],
        referenceEndpoints: (CGPoint, CGPoint),
        reference: Reference
    ) -> CardMeasurement? {
        guard cardCorners.count == 4 else { return nil }

        let refPointLength = distance(referenceEndpoints.0, referenceEndpoints.1)
        guard refPointLength > 0.5 else { return nil }

        let mmPerPoint = reference.lengthMM / refPointLength

        // Average opposite edges to cancel small marking asymmetry, matching the
        // AR path's approach.
        let (tl, tr, br, bl) = (cardCorners[0], cardCorners[1], cardCorners[2], cardCorners[3])
        let top = distance(tl, tr)
        let bottom = distance(bl, br)
        let left = distance(tl, bl)
        let right = distance(tr, br)

        let widthMM = (top + bottom) / 2 * mmPerPoint
        let heightMM = (left + right) / 2 * mmPerPoint

        guard widthMM > 5, heightMM > 5 else { return nil }

        // Marking by hand is coarser than AR; report a fixed modest confidence
        // rather than implying precision the method doesn't have.
        return CardMeasurement(widthMM: widthMM, heightMM: heightMM, confidence: 0.6).normalized
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }
}
