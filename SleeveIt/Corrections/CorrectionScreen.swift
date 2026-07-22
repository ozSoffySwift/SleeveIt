import SwiftUI
import SwiftData

/// Form for suggesting a catalog fix or a missing game.
struct CorrectionScreen: View {
    enum Mode: Equatable {
        case fixGame(id: String, title: String)
        case newGame(prefilledTitle: String)
    }

    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var title = ""
    @State private var details = ""
    @State private var state: SubmitState = .editing

    private enum SubmitState: Equatable {
        case editing
        case submitting
        case sent
        case failed(String)
    }

    private var isFix: Bool {
        if case .fixGame = mode { return true }
        return false
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !details.trimmingCharacters(in: .whitespaces).isEmpty
            && state != .submitting
    }

    var body: some View {
        NavigationStack {
            Form {
                if !CorrectionService.isConfigured {
                    setupNote
                }

                Section("Game") {
                    if isFix {
                        Text(title).foregroundStyle(.secondary)
                    } else {
                        TextField("Game title", text: $title)
                    }
                }

                Section {
                    TextField(detailsPrompt, text: $details, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text(isFix ? "What's wrong?" : "Card breakdown")
                } footer: {
                    Text(isFix
                         ? "Tell us which deck and the correct count, e.g. \"Bird cards should be 178, not 170\"."
                         : "List each deck, its card count and size if you know it, e.g. \"120 cards at 63.5×88, 30 mini\".")
                }

                if case .sent = state {
                    Section {
                        Label("Thanks — your report was sent.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.good)
                    }
                }
                if case .failed(let message) = state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                        // Compose an email as a fallback path when the backend
                        // isn't reachable, so the report isn't simply lost.
                        Button("Send as email instead") { composeEmail() }
                    }
                }
            }
            .navigationTitle(isFix ? "Suggest a correction" : "Add a game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if state == .submitting {
                        ProgressView()
                    } else {
                        Button("Send") { submit() }
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear {
                switch mode {
                case .fixGame(_, let t): title = t
                case .newGame(let prefilled): title = prefilled
                }
            }
        }
    }

    private var detailsPrompt: String {
        isFix ? "Describe the correction" : "Decks, counts and sizes"
    }

    private var setupNote: some View {
        Section {
            Label {
                Text("This build has no submission endpoint yet, so reports are sent by email. See the README to wire up the backend.")
                    .font(.system(size: 13))
            } icon: {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    // MARK: - Submit

    private func makeReport() -> CorrectionReport {
        let (kind, gameID): (CorrectionReport.Kind, String?) = {
            switch mode {
            case .fixGame(let id, _): return (.cardCountFix, id)
            case .newGame: return (.newGame, nil)
            }
        }()
        return CorrectionReport(
            kind: kind,
            gameID: gameID,
            gameTitle: title.trimmingCharacters(in: .whitespaces),
            details: details.trimmingCharacters(in: .whitespaces),
            submittedAt: .now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            catalogVersion: UserDefaults.standard.integer(forKey: "catalog.version")
        )
    }

    private func submit() {
        let report = makeReport()

        // No backend configured → go straight to the email fallback rather than
        // pretend to submit.
        guard CorrectionService.isConfigured else {
            composeEmail(report)
            state = .sent
            return
        }

        state = .submitting
        Task {
            do {
                try await CorrectionService().submit(report)
                state = .sent
            } catch {
                state = .failed((error as? CorrectionError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func composeEmail(_ report: CorrectionReport? = nil) {
        let r = report ?? makeReport()
        let subject = r.kind == .cardCountFix
            ? "SleeveIt correction: \(r.gameTitle)"
            : "SleeveIt new game: \(r.gameTitle)"
        let body = """
        \(r.details)

        —
        Game: \(r.gameTitle)\(r.gameID.map { " (\($0))" } ?? "")
        App \(r.appVersion) · catalog v\(r.catalogVersion)
        """
        var components = URLComponents(string: "mailto:catalog@sleeveit.app")!
        components.queryItems = [
            .init(name: "subject", value: subject),
            .init(name: "body", value: body),
        ]
        if let url = components.url {
            openURL(url)
        }
    }
}
