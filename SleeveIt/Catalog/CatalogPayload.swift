import Foundation

/// Wire format for the catalog — shared by the bundled seed and the remote feed.
///
/// The catalog is versioned by an integer. A payload is only applied when its
/// version is greater than the one already stored, so a bad deploy can be rolled
/// back by shipping a higher version with corrected data.
struct CatalogPayload: Codable {
    var version: Int
    var updatedAt: Date
    var sizes: [SizeDTO]
    var games: [GameDTO]

    struct SizeDTO: Codable {
        var id: String
        var name: String
        var widthMM: Double
        var heightMM: Double
        var tagline: String
        var blurb: String
        var examples: [String]
        var isCommon: Bool?
    }

    struct GameDTO: Codable {
        var id: String
        var title: String
        var publisher: String
        var year: Int
        var aliases: [String]?
        var baseGameID: String?
        var decks: [DeckDTO]
    }

    struct DeckDTO: Codable {
        var label: String
        var count: Int
        var sizeID: String
    }
}

extension JSONDecoder {
    static var catalog: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
