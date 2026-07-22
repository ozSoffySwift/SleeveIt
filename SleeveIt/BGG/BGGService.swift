import Foundation
import os

/// One game owned by a BoardGameGeek user.
struct BGGCollectionItem: Identifiable, Equatable {
    var id: String          // BGG object id
    var title: String
    var year: Int?
}

enum BGGError: LocalizedError, Equatable {
    case notConfigured
    case emptyUsername
    case unauthorized
    case userNotFound
    case privateCollection
    case stillQueued
    case rateLimited
    case network(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "This build has no BoardGameGeek API token."
        case .emptyUsername:
            "Enter your BoardGameGeek username."
        case .unauthorized:
            "BoardGameGeek rejected the app's API token."
        case .userNotFound:
            "No BoardGameGeek user by that name."
        case .privateCollection:
            "That collection is private. Make it public on BGG, then try again."
        case .stillQueued:
            "BoardGameGeek is still preparing your collection. Try again in a moment."
        case .rateLimited:
            "BoardGameGeek is rate-limiting requests. Wait a minute and try again."
        case .network(let detail):
            detail
        case .malformedResponse:
            "BoardGameGeek returned something SleeveIt couldn't read."
        }
    }
}

/// Read-only client for the BoardGameGeek XML API.
///
/// **One-way by design.** This only ever issues GETs. SleeveIt never writes to a
/// BGG account, and the only thing that leaves the device is the username being
/// looked up (plus the app's own API token). Nothing about the user's SleeveIt
/// list is ever sent anywhere.
///
/// Since late October 2025 the XML API requires a registered application and a
/// bearer token; anonymous requests get a 401 on every endpoint. See
/// `BGGConfiguration` for how to supply one.
struct BGGService {
    private let logger = Logger(subsystem: "com.sleeveit.SleeveIt", category: "bgg")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches the games a user marks as owned.
    ///
    /// BGG queues collection requests and answers `202` until the export is
    /// ready, so this polls with a delay rather than failing on the first call.
    func ownedCollection(username: String, maxAttempts: Int = 5) async throws -> [BGGCollectionItem] {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BGGError.emptyUsername }
        guard BGGConfiguration.isConfigured else { throw BGGError.notConfigured }

        var components = URLComponents(string: "https://boardgamegeek.com/xmlapi2/collection")!
        components.queryItems = [
            .init(name: "username", value: trimmed),
            .init(name: "own", value: "1"),
            .init(name: "subtype", value: "boardgame"),
            .init(name: "excludesubtype", value: "boardgameexpansion"),
            .init(name: "brief", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("SleeveIt/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(BGGConfiguration.apiToken)", forHTTPHeaderField: "Authorization")

        for attempt in 1...maxAttempts {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw BGGError.network(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw BGGError.malformedResponse
            }

            switch http.statusCode {
            case 200:
                return try Self.parse(data)

            case 202:
                // Queued. BGG asks callers to back off and retry.
                logger.debug("BGG queued the request (attempt \(attempt))")
                if attempt == maxAttempts { throw BGGError.stillQueued }
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))

            case 401, 403:
                throw BGGError.unauthorized

            case 404:
                throw BGGError.userNotFound

            case 429:
                throw BGGError.rateLimited

            default:
                throw BGGError.network("BoardGameGeek returned status \(http.statusCode).")
            }
        }

        throw BGGError.stillQueued
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> [BGGCollectionItem] {
        let parser = CollectionParser()
        guard parser.parse(data) else { throw BGGError.malformedResponse }
        if parser.sawPrivateError { throw BGGError.privateCollection }
        if parser.sawInvalidUser { throw BGGError.userNotFound }
        return parser.items
    }
}

/// Streaming XML parser for a `<items>` collection response.
private final class CollectionParser: NSObject, XMLParserDelegate {
    private(set) var items: [BGGCollectionItem] = []
    private(set) var sawPrivateError = false
    private(set) var sawInvalidUser = false

    private var currentID: String?
    private var currentYear: Int?
    private var currentName = ""
    private var isCapturingName = false
    private var messageBuffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "item":
            currentID = attributes["objectid"]
            currentName = ""
            currentYear = nil
        case "name":
            isCapturingName = true
        case "yearpublished":
            // Reset the buffer, or it still holds the name text that preceded it.
            isCapturingName = false
            messageBuffer = ""
        case "error", "message":
            messageBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCapturingName {
            currentName += string
        }
        messageBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "name":
            isCapturingName = false
        case "yearpublished":
            currentYear = Int(messageBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            messageBuffer = ""
        case "item":
            let title = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = currentID, !title.isEmpty {
                items.append(BGGCollectionItem(id: id, title: title, year: currentYear))
            }
            currentID = nil
            currentName = ""
            currentYear = nil
        case "message", "error":
            let text = messageBuffer.lowercased()
            if text.contains("private") { sawPrivateError = true }
            if text.contains("invalid user") || text.contains("not found") { sawInvalidUser = true }
            messageBuffer = ""
        default:
            break
        }
    }
}
