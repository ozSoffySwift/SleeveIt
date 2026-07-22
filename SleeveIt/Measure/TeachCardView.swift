import SwiftUI
import SwiftData
import PhotosUI

/// Teaches SleeveIt to recognise a game's card from its artwork.
///
/// The user picks a clear photo of the card face; SleeveIt computes a Vision
/// feature print and stores it against the game. Enough tagged cards and the
/// measure flow can name the game from a card's look, not just its size.
struct TeachCardView: View {
    let gameID: String
    let gameTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var learned: [LearnedCardPrint]

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var label = ""
    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable { case idle, saving, saved, failed }

    private var taughtForThisGame: Int {
        learned.filter { $0.gameID == gameID }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Photograph a card face from \(gameTitle) in good light, filling the frame. SleeveIt learns what it looks like — nothing leaves your device.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Section("Card photo") {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(image == nil ? "Choose a photo" : "Choose a different photo",
                              systemImage: "photo")
                    }
                }

                Section {
                    TextField("Label (e.g. \"Bird card\")", text: $label)
                }

                if taughtForThisGame > 0 {
                    Section {
                        Label("\(taughtForThisGame) card\(taughtForThisGame == 1 ? "" : "s") already taught for \(gameTitle)",
                              systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.good)
                    }
                }

                if saveState == .saved {
                    Section {
                        Label("Saved. Teach a few different cards for the best results.",
                              systemImage: "brain.head.profile")
                            .foregroundStyle(Theme.good)
                    }
                }
                if saveState == .failed {
                    Section {
                        Label("Couldn't read that image. Try a sharper, closer photo.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            .navigationTitle("Teach a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saveState == .saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(image == nil)
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                Task { await load(item) }
            }
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data)
        else { return }
        image = uiImage
        saveState = .idle
    }

    private func save() {
        guard let cgImage = image?.cgImage else { saveState = .failed; return }
        saveState = .saving
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty
            ? gameTitle : label.trimmingCharacters(in: .whitespaces)
        let ok = LearnedPrintStore.teach(gameID: gameID, label: name, image: cgImage, in: context)
        saveState = ok ? .saved : .failed
        if ok {
            image = nil
            pickerItem = nil
            label = ""
        }
    }
}
