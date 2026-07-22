import Foundation
import os

/// A user-submitted catalog correction or new-game suggestion.
///
/// The wire shape the backend receives. Keep it stable — it's the contract
/// documented in the README for whatever endpoint the user stands up.
struct CorrectionReport: Codable {
    enum Kind: String, Codable {
        case cardCountFix   // a deck count is wrong on an existing game
        case newGame        // a game missing from the catalog
    }

    var kind: Kind
    /// Catalog id of the game being corrected; nil for a brand-new game.
    var gameID: String?
    var gameTitle: String
    /// Free text: which deck / what's wrong, or the new game's card breakdown.
    var details: String
    var submittedAt: Date
    var appVersion: String
    var catalogVersion: Int
}

enum CorrectionError: LocalizedError {
    case notConfigured
    case network(String)
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Corrections aren't set up in this build yet."
        case .network(let detail):
            detail
        case .rejected(let code):
            "The server rejected the report (status \(code))."
        }
    }
}

/// Submits corrections to a backend the app owner operates.
///
/// **The app side is complete; the backend is not — it can't be, from inside an
/// app.** Point `endpoint` at a `POST` handler you run (see README for the full
/// contract: it receives one `CorrectionReport` as JSON, queues it for
/// moderation, and an approved fix becomes a bumped `catalog.json` version that
/// the existing `CatalogStore.refresh()` then pulls). Until `endpoint` is set,
/// `isConfigured` is false and the UI shows a setup note instead of failing.
struct CorrectionService {
    /// Your submission endpoint. Placeholder until you host one.
    static let endpoint = URL(string: "https://catalog.sleeveit.app/v1/corrections")!

    /// Flip to true once `endpoint` points at a real handler. Kept explicit so a
    /// placeholder URL can't silently look "configured".
    static let isConfigured = false

    private let logger = Logger(subsystem: "com.sleeveit.SleeveIt", category: "corrections")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func submit(_ report: CorrectionReport) async throws {
        guard Self.isConfigured else { throw CorrectionError.notConfigured }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SleeveIt/1.0", forHTTPHeaderField: "User-Agent")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(report)

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw CorrectionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CorrectionError.network("No response from server.")
        }
        guard (200...299).contains(http.statusCode) else {
            logger.error("Correction rejected: \(http.statusCode)")
            throw CorrectionError.rejected(http.statusCode)
        }
    }
}
