import SwiftUI
import StoreKit

/// "About the Developer" — a short bio, links to the developer's other apps and
/// GitHub, and a native path to rate & review SleeveIt on the App Store.
struct DeveloperScreen: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview

    private enum Link {
        /// The developer's App Store page (all of Oz Soffy's apps).
        static let moreApps = URL(string: "https://apps.apple.com/developer/oz-soffy/id790394995")!
        static let github = URL(string: "https://github.com/ozsoffy")!
        /// Opens the App Store review sheet for SleeveIt directly.
        static let writeReview = URL(string: "https://apps.apple.com/app/id6793905893?action=write-review")!
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.accent)
                    Text("Oz Soffy")
                        .font(.system(size: 22, weight: .bold))
                    Text("Independent iOS Developer")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("Hi, I'm Oz — an independent developer who builds small, focused apps for tabletop gamers and everyday life. SleeveIt started from a simple frustration: never knowing which sleeves a game actually needs, or how many to buy. I build these apps solo, on nights and weekends, and read every piece of feedback.")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
            }

            Section {
                Button {
                    AppAnalytics.log(.reviewRequested)
                    // The in-app prompt is the nicest experience when the system
                    // allows it; the write-review link is the guaranteed path to
                    // the App Store review sheet.
                    requestReview()
                    openURL(Link.writeReview)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Rate & Review SleeveIt")
                                .font(.system(size: 16, weight: .semibold))
                            Text("A quick review helps other gamers find it")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .buttonStyle(.plain)
            }

            Section("More from Oz") {
                DeveloperLinkRow(
                    title: "More apps by Oz Soffy",
                    subtitle: "See everything on the App Store",
                    systemImage: "square.stack.3d.up.fill",
                    url: Link.moreApps
                )
                DeveloperLinkRow(
                    title: "GitHub",
                    subtitle: "github.com/ozsoffy",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    url: Link.github
                )
            }
        }
        .navigationTitle("About the Developer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { AppAnalytics.log(.screenViewed(name: "developer")) }
    }
}

/// An external-link row that opens in the browser / App Store.
private struct DeveloperLinkRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
