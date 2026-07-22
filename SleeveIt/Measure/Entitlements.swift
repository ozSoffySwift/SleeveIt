import Foundation
import Combine

/// What the current user is entitled to.
///
/// The free/paid split:
///
/// | | Free | Pro |
/// |---|---|---|
/// | Measure a card's size | 5 per day | unlimited |
/// | Recommended sleeve | ✓ | ✓ |
/// | Identify which game the card is from | — | ✓ |
/// | Full deck breakdown for that game | — | ✓ |
/// | Add every deck to the basket at once | — | ✓ |
///
/// `isPro` is the single switch. Nothing sets it to true today — wire it to a
/// StoreKit 2 entitlement check when purchasing ships and every gate below
/// opens at once.
@MainActor
final class Entitlements: ObservableObject {
    static let shared = Entitlements()

    @Published var isPro: Bool = false

    init(isPro: Bool = false) {
        self.isPro = isPro
    }
}
