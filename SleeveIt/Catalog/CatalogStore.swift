import Foundation
import SwiftData
import os

/// Owns the catalog lifecycle: seed from the bundle on first launch, then refresh
/// from a remote feed.
///
/// The catalog is server-owned data — it is replaced wholesale on every apply, so
/// games removed upstream disappear locally. User data (`ListEntry`,
/// `RecentLookup`) references catalog rows by string id rather than by SwiftData
/// relationship, so a catalog refresh never orphans or deletes anything the user
/// created.
@MainActor
final class CatalogStore {
    /// Where the refreshed catalog is fetched from. Point this at your own
    /// static host (S3/R2/GitHub Pages) — see README for the payload contract.
    static let remoteURL = URL(string: "https://catalog.sleeveit.app/v1/catalog.json")!

    private let logger = Logger(subsystem: "com.sleeveit.SleeveIt", category: "catalog")
    private let context: ModelContext
    private let defaults: UserDefaults

    private enum Key {
        static let version = "catalog.version"
        static let etag = "catalog.etag"
        static let lastCheck = "catalog.lastCheck"
    }

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
    }

    var installedVersion: Int { defaults.integer(forKey: Key.version) }

    // MARK: - Seeding

    /// Loads the bundled catalog if the store is empty or the bundle ships a
    /// newer version than what is installed (i.e. after an app update).
    func seedIfNeeded() {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            logger.error("Bundled catalog.json is missing from the app target")
            return
        }

        do {
            let payload = try JSONDecoder.catalog.decode(CatalogPayload.self, from: Data(contentsOf: url))
            guard payload.version > installedVersion || isEmpty else { return }
            try apply(payload)
            logger.info("Seeded catalog v\(payload.version) from bundle")
        } catch {
            logger.error("Failed to seed catalog: \(error.localizedDescription)")
        }
    }

    private var isEmpty: Bool {
        let count = try? context.fetchCount(FetchDescriptor<SleeveSize>())
        return (count ?? 0) == 0
    }

    // MARK: - Refresh

    /// Fetches the remote catalog and applies it when it is newer.
    ///
    /// Uses an ETag so an unchanged catalog costs a 304 and no body. Failures are
    /// non-fatal by design: the bundled/last-synced catalog stays in place, which
    /// is what keeps the app fully usable offline.
    @discardableResult
    func refresh() async -> Bool {
        var request = URLRequest(url: Self.remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if let etag = defaults.string(forKey: Key.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            defaults.set(Date.now, forKey: Key.lastCheck)

            guard let http = response as? HTTPURLResponse else { return false }

            if http.statusCode == 304 {
                logger.debug("Catalog unchanged (304)")
                return false
            }
            guard http.statusCode == 200 else {
                logger.error("Catalog fetch failed with status \(http.statusCode)")
                return false
            }

            let payload = try JSONDecoder.catalog.decode(CatalogPayload.self, from: data)
            guard payload.version > installedVersion else {
                logger.debug("Catalog v\(payload.version) is not newer than v\(self.installedVersion)")
                return false
            }

            try apply(payload)
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                defaults.set(etag, forKey: Key.etag)
            }
            logger.info("Applied catalog v\(payload.version)")
            return true
        } catch {
            logger.error("Catalog refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Apply

    private func apply(_ payload: CatalogPayload) throws {
        // Deleted one by one rather than with `context.delete(model:)`: a batch
        // delete bypasses the cascade rule and trips the mandatory inverse on
        // CardDeck.game, which silently leaves the old catalog in place.
        for game in try context.fetch(FetchDescriptor<Game>()) {
            context.delete(game)
        }
        for deck in try context.fetch(FetchDescriptor<CardDeck>()) {
            context.delete(deck)
        }
        for size in try context.fetch(FetchDescriptor<SleeveSize>()) {
            context.delete(size)
        }
        try context.save()

        for (index, dto) in payload.sizes.enumerated() {
            context.insert(SleeveSize(
                id: dto.id,
                name: dto.name,
                widthMM: dto.widthMM,
                heightMM: dto.heightMM,
                tagline: dto.tagline,
                blurb: dto.blurb,
                examples: dto.examples,
                isCommon: dto.isCommon ?? false,
                sortIndex: index
            ))
        }

        for dto in payload.games {
            let game = Game(
                id: dto.id,
                title: dto.title,
                publisher: dto.publisher,
                year: dto.year,
                aliases: dto.aliases ?? [],
                baseGameID: dto.baseGameID
            )
            context.insert(game)
            for (index, deck) in dto.decks.enumerated() {
                let model = CardDeck(
                    label: deck.label,
                    count: deck.count,
                    sizeID: deck.sizeID,
                    sortIndex: index
                )
                model.game = game
                context.insert(model)
            }
        }

        try context.save()
        defaults.set(payload.version, forKey: Key.version)
    }
}
