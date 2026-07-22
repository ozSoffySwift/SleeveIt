import SwiftData
import Vision
import CoreGraphics
import Foundation

/// Bridges the `LearnedCardPrint` SwiftData corpus and `CardArtworkRecognizer`.
@MainActor
enum LearnedPrintStore {

    /// Teaches a card: generates a feature print and stores it for a game.
    @discardableResult
    static func teach(
        gameID: String,
        label: String,
        image: CGImage,
        in context: ModelContext
    ) -> Bool {
        guard let observation = try? CardArtworkRecognizer.featurePrint(for: image),
              let data = CardArtworkRecognizer.archive(observation)
        else { return false }
        context.insert(LearnedCardPrint(gameID: gameID, label: label, printData: data))
        try? context.save()
        return true
    }

    /// Every stored print, decoded for ranking. Prints that fail to decode are
    /// skipped so one bad row can't break recognition.
    static func references(
        in context: ModelContext
    ) -> [(gameID: String, label: String, print: VNFeaturePrintObservation)] {
        let stored = (try? context.fetch(FetchDescriptor<LearnedCardPrint>())) ?? []
        return stored.compactMap { row in
            guard let print = CardArtworkRecognizer.unarchive(row.printData) else { return nil }
            return (row.gameID, row.label, print)
        }
    }

    /// Recognises a card image against the learned corpus, returning the best
    /// game id within threshold, or nil.
    static func recognize(image: CGImage, in context: ModelContext) -> String? {
        guard let query = try? CardArtworkRecognizer.featurePrint(for: image) else { return nil }
        return CardArtworkRecognizer.bestGameID(query: query, against: references(in: context))
    }

    static func hasCorpus(in context: ModelContext) -> Bool {
        let count = try? context.fetchCount(FetchDescriptor<LearnedCardPrint>())
        return (count ?? 0) > 0
    }
}
