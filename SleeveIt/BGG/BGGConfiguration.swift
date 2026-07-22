import Foundation

/// Where the BoardGameGeek API token comes from.
///
/// Since late October 2025 the BGG XML API rejects anonymous requests with a
/// 401 on every endpoint. Using it requires registering an application with BGG
/// and sending the issued token as a bearer header.
///
/// **To enable the BGG import:**
/// 1. Register the app at <https://boardgamegeek.com/using_the_xml_api>.
/// 2. Put the issued token in `BGGToken.plist` (see below), or set it as the
///    `BGG_API_TOKEN` build setting and expose it via Info.plist.
///
/// The token is read from a plist that is *not* committed, so it doesn't end up
/// in source control. Until one is supplied, `isConfigured` is false and the
/// import screen shows a setup message instead of failing at request time.
///
/// A caveat worth knowing: any token shipped inside an app binary is
/// extractable by a determined user. That is inherent to BGG's model for client
/// apps — treat the token as an identifier, not a secret, and be ready to
/// rotate it if it gets abused.
enum BGGConfiguration {
    /// Reads the token from `BGGToken.plist` (key `token`), falling back to the
    /// `BGG_API_TOKEN` Info.plist entry for CI-injected builds.
    static let apiToken: String = {
        if let url = Bundle.main.url(forResource: "BGGToken", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let token = plist["token"] as? String,
           !token.isEmpty {
            return token
        }
        if let token = Bundle.main.object(forInfoDictionaryKey: "BGG_API_TOKEN") as? String,
           !token.isEmpty, !token.hasPrefix("$(") {
            return token
        }
        return ""
    }()

    static var isConfigured: Bool { !apiToken.isEmpty }

    static let registrationURL = URL(string: "https://boardgamegeek.com/using_the_xml_api")!
}
