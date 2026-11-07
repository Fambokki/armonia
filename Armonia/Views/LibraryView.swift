import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var showSpotify = false
    @State private var showSettings = false
    @State private var showFilePicker = false
    @State private var importing: (done: Int, total: Int)?
    @State private var importMessage: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TrackListScreen(source: .favorites)
                } label: {
                    Label("Preferiti", systemImage: "heart.fill")
                        .badge(library.favorites.count)
                }
                NavigationLink {
                    TrackListScreen(source: .downloads)
                } label: {
                    Label("Scaricati", systemImage: "arrow.down.circle.fill")
                        .badge(library.downloads.count)
                }
                NavigationLink {
                    TrackListScreen(source: .locals)
                } label: {
                    Label("File importati", systemImage: "internaldrive")
                        .badge(library.locals.count)
                }
                NavigationLink {
                    TrackListScreen(source: .recents)
                } label: {
                    Label("Ascoltati di recente", systemImage: "clock")
                }
            }

            if downloads.activeCount > 0 {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Download in corso: \(downloads.activeCount)")
                        Spacer()
                        Button("Annulla") { downloads.cancelAll() }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section("Playlist") {
                Button {
                    newName = ""
                    showNewPlaylist = true
                } label: {
                    Label("Nuova playlist", systemImage: "plus")
                }
                ForEach(library.playlists) { p in
                    NavigationLink {
                        TrackListScreen(source: .playlist(p.id))
                    } label: {
                        Label(p.name, systemImage: "music.note.list")
                            .badge(p.tracks.count)
                    }
                }
                .onDelete { library.deletePlaylists(at: $0) }
            }
        }
        .navigationTitle("Libreria")
        .navigationDestination(for: BrowseTarget.self) { BrowsePageView(target: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = ""; showNewPlaylist = true } label: {
                        Label("Nuova playlist", systemImage: "music.note.list")
                    }
                    Button { showSpotify = true } label: {
                        Label("Importa da Spotify", systemImage: "square.and.arrow.down")
                    }
                    Button { showFilePicker = true } label: {
                        Label("Importa file audio (FLAC, ALAC…)", systemImage: "waveform.badge.plus")
                    }
                    Divider()
                    ShareLink(item: library.fileURL) {
                        Label("Esporta libreria (JSON)", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let importing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Importo i file… \(importing.done)/\(importing.total)")
                }
                .padding(12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 90)
            }
        }
        .alert("Nuova playlist", isPresented: $showNewPlaylist) {
            TextField("Nome", text: $newName)
            Button("Crea") {
                if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.createPlaylist(newName)
                }
            }
            Button("Annulla", role: .cancel) {}
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showSpotify) { SpotifyImportView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            importFiles(urls)
        }
    }

    private func importFiles(_ urls: [URL]) {
        importing = (0, urls.count)
        Task {
            var ok = 0
            var failed: [String] = []
            for (i, u) in urls.enumerated() {
                do {
                    let t = try await LocalImporter.importFile(u)
                    library.addLocal(t)
                    ok += 1
                } catch {
                    failed.append(u.lastPathComponent)
                }
                importing = (i + 1, urls.count)
            }
            importing = nil
            importMessage = failed.isEmpty
                ? "Importati \(ok) file. Li trovi in \"File importati\"."
                : "Importati \(ok) file. Non riusciti: \(failed.joined(separator: ", "))"
        }
    }
}

struct TrackListScreen: View {
    let source: TrackSource

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @State private var showRename = false
    @State private var newName = ""

    private var tracks: [Track] { library.tracks(for: source) }

    private var playlistID: UUID? {
        if case .playlist(let id) = source { return id }
        return nil
    }

    /// Riordinare ha senso solo nelle playlist.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard let id = playlistID else { return nil }
        let store = library
        return { from, to in store.move(from: from, to: to, in: id) }
    }

    private var emptyText: String {
        switch source {
        case .downloads: return "Scarica brani, album o playlist dal menu ··· per ascoltarli senza internet."
        case .locals: return "Importa i tuoi file FLAC, ALAC o MP3 dal pulsante + nella Libreria."
        default: return "Aggiungi brani dal menu ··· accanto a ogni canzone."
        }
    }

    var body: some View {
        List {
            if !tracks.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            player.play(tracks)
                        } label: {
                            Label("Riproduci", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        Button {
                            player.play(tracks.shuffled())
                        } label: {
                            Label("Casuale", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    switch source {
                    case .downloads:
                        Text("\(tracks.count) brani · \(formatBytes(Storage.size(of: Storage.downloads)))")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .locals:
                        Text("\(tracks.count) file · \(formatBytes(Storage.size(of: Storage.locals)))")
                            .font(.footnote).foregroundStyle(.secondary)
                    default:
                        DownloadAllButton(tracks: tracks)
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                    }
                }
                .listRowSeparator(.hidden)
            }

            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t) { player.play(tracks, startAt: i) }
            }
            .onDelete { library.remove(at: $0, from: source) }
            .onMove(perform: moveAction)
        }
        .listStyle(.plain)
        .navigationTitle(library.title(for: source))
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Ancora vuota", systemImage: "music.note", description: Text(emptyText))
            }
        }
        .toolbar {
            if playlistID != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        newName = library.title(for: source)
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    EditButton()
                }
            }
        }
        .alert("Rinomina playlist", isPresented: $showRename) {
            TextField("Nome", text: $newName)
            Button("Salva") {
                if let id = playlistID, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.renamePlaylist(id, to: newName)
                }
            }
            Button("Annulla", role: .cancel) {}
        }
    }
}
