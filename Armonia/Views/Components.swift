import SwiftUI
import AVKit

struct ArtworkView: View, Equatable {
    let url: URL?
    var corner: CGFloat = 6
    /// Lato massimo in pixel a cui decodificare l'immagine (miniature piccole = meno memoria).
    var pixelSize: Int = 300

    @State private var image: UIImage?

    static func == (a: ArtworkView, b: ArtworkView) -> Bool {
        a.url == b.url && a.corner == b.corner && a.pixelSize == b.pixelSize
    }

    var body: some View {
        // Se l'immagine è già in memoria la si mostra subito, senza un fotogramma vuoto.
        let shown = image ?? url.flatMap { ImageCache.shared.cached($0, size: pixelSize) }
        Color.gray.opacity(0.22)
            .overlay {
                if let shown {
                    Image(uiImage: shown).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .task(id: url) {
                guard let url else { image = nil; return }
                if let c = ImageCache.shared.cached(url, size: pixelSize) { image = c; return }
                image = nil
                let loaded = await ImageCache.shared.image(for: url, size: pixelSize)
                if !Task.isCancelled { image = loaded }
            }
    }
}

struct TrackRow: View {
    let track: Track
    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
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
                DownloadBadge(track: track)
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
        if !track.isPodcast && !track.isLocal {
            Button { player.startRadio(from: track) } label: { Label("Avvia radio", systemImage: "dot.radiowaves.left.and.right") }
        }
        Divider()
        Button { library.toggleFavorite(track) } label: {
            library.isFavorite(track)
                ? Label("Rimuovi dai preferiti", systemImage: "heart.slash")
                : Label("Aggiungi ai preferiti", systemImage: "heart")
        }
        Button { showPlaylistPicker = true } label: { Label("Aggiungi a playlist", systemImage: "music.note.list") }
        Divider()
        if track.isLocal {
            Button(role: .destructive) { library.removeLocal(track) } label: {
                Label("Elimina file", systemImage: "trash")
            }
        } else if library.isDownloaded(track) {
            Button(role: .destructive) { library.removeDownload(track) } label: {
                Label("Rimuovi download", systemImage: "trash")
            }
        } else if downloads.isQueued(track) {
            Button { downloads.cancel(track) } label: { Label("Annulla download", systemImage: "xmark.circle") }
        } else {
            Button { downloads.download([track]) } label: { Label("Scarica", systemImage: "arrow.down.circle") }
        }
    }
}

/// Icona accanto ai brani: scaricato, in download (con avanzamento) o errore.
struct DownloadBadge: View {
    let track: Track
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        if let p = downloads.progress[track.id] {
            ProgressView(value: p)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: 18, height: 18)
        } else if track.isLocal {
            Image(systemName: "internaldrive").font(.caption).foregroundStyle(.secondary)
        } else if library.isDownloaded(track) {
            Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.tint)
        } else if downloads.failures[track.id] != nil {
            Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
        }
    }
}

/// Pulsante "Scarica tutto" per album e playlist.
struct DownloadAllButton: View {
    let tracks: [Track]
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    private var missing: [Track] { tracks.filter { !$0.isLocal && !library.isDownloaded($0) } }
    private var running: Bool { tracks.contains { downloads.isQueued($0) } }

    var body: some View {
        if !tracks.isEmpty {
            if running {
                Button { tracks.forEach { downloads.cancel($0) } } label: {
                    Label("Download in corso…", systemImage: "xmark.circle")
                }
            } else if missing.isEmpty {
                Label("Tutto scaricato", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button { downloads.download(missing) } label: {
                    Label("Scarica (\(missing.count))", systemImage: "arrow.down.circle")
                }
            }
        }
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
                        TextField("Nuova playlist", text: $newName, axis: .vertical)
                            .lineLimit(1...4)
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
