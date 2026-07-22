import Vision
import CoreGraphics
import Foundation

/// On-device artwork recognition using Vision feature prints.
///
/// **Why "learned", not "shipped".** True out-of-the-box recognition would need a
/// labelled reference image for every card of every game — a corpus that doesn't
/// exist and that can't be bundled (the card faces are copyrighted). So instead
/// the corpus is built by the user: when they confirm which game a measured card
/// belongs to, they can teach SleeveIt what that card looks like. Each lesson
/// stores a `VNFeaturePrintObservation`; recognition then ranks a new card's
/// print against everything taught so far.
///
/// The whole pipeline here is real and tested. What's absent is the corpus —
/// recognition returns nothing until the user (or a future data drop) provides
/// reference prints. `GameIdentifying` is where the ranked result plugs in.
enum CardArtworkRecognizer {

    struct Match {
        var gameID: String
        var label: String
        /// Vision distance — smaller is more similar.
        var distance: Float
    }

    /// A confident-enough distance to treat as a real artwork match. Vision
    /// feature-print distances for the same card typically sit well below this;
    /// unrelated images are far higher.
    static let matchThreshold: Float = 20

    enum RecognizerError: Error { case cannotGeneratePrint }

    /// Computes a feature print for a card image.
    static func featurePrint(for cgImage: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw RecognizerError.cannotGeneratePrint
        }
        return observation
    }

    /// Distance between two prints, or nil if Vision can't compare them (e.g.
    /// prints produced by incompatible revisions).
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var value = Float(0)
        do {
            try a.computeDistance(&value, to: b)
            return value
        } catch {
            return nil
        }
    }

    // MARK: - Persistence

    /// `VNFeaturePrintObservation` is `NSSecureCoding`, so it round-trips through
    /// a keyed archive — that's how a learned print is stored in SwiftData.
    static func archive(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: data)
    }

    // MARK: - Ranking

    /// Ranks reference prints against a query, nearest first. Prints that fail to
    /// compare are dropped rather than crashing the match.
    static func rank(
        query: VNFeaturePrintObservation,
        against references: [(gameID: String, label: String, print: VNFeaturePrintObservation)]
    ) -> [Match] {
        references
            .compactMap { reference -> Match? in
                guard let d = distance(query, reference.print) else { return nil }
                return Match(gameID: reference.gameID, label: reference.label, distance: d)
            }
            .sorted { $0.distance < $1.distance }
    }

    /// The best game id if any reference is within `matchThreshold`.
    static func bestGameID(
        query: VNFeaturePrintObservation,
        against references: [(gameID: String, label: String, print: VNFeaturePrintObservation)]
    ) -> String? {
        guard let best = rank(query: query, against: references).first,
              best.distance <= matchThreshold else { return nil }
        return best.gameID
    }
}
