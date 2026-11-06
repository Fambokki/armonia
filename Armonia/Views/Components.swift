import SwiftUI
import AVKit

struct ArtworkView: View {
    let url: URL?
    var corner: CGFloat = 6

    var body: some View {
        Color.gray.opacity(0.22)
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct TrackRow: View {
    let track: Track
    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var showPlaylistPicker = false

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(url: track.artworkURL)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Text([track.artist, track.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent && player.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Menu {
                trackActions
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .contextMenu { trackActions }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPicker(track: track)
        }
    }

    @ViewBuilder
    private var trackActions: some View {
        Button { player.playNext(track) } label: { Label("Riproduci dopo", systemImage: "text.insert") }
        Button { player.addToQueue(track) } label: { Label("Aggiungi in coda", systemImage: "text.append") }
        Button { player.startRadio(from: track) } label: { Label("Avvia radio", systemImage: "dot.radiowaves.left.and.right") }
        Divider()
        Button { library.toggleFavorite(track) } label: {
            library.isFavorite(track)
                ? Label("Rimuovi dai preferiti", systemImage: "heart.slash")
                : Label("Aggiungi ai preferiti", systemImage: "heart")
        }
        Button { showPlaylistPicker = true } label: { Label("Aggiungi a playlist", systemImage: "music.note.list") }
    }
}

struct PlaylistPicker: View {
    let track: Track
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Nuova playlist", text: $newName)
                        Button("Crea") {
                            let id = library.createPlaylist(newName)
                            library.add(track, to: id)
                            dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !library.playlists.isEmpty {
                    Section("Le tue playlist") {
                        ForEach(library.playlists) { p in
                            Button {
                                library.add(track, to: p.id)
                                dismiss()
                            } label: {
                                Label(p.name, systemImage: "music.note.list")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Aggiungi a playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Pulsante di sistema per scegliere l'uscita audio (AirPlay, Bluetooth).
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .secondaryLabel
        v.activeTintColor = .systemPink
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
