import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showNewPlaylist = false
    @State private var newName = ""

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
                    TrackListScreen(source: .recents)
                } label: {
                    Label("Ascoltati di recente", systemImage: "clock")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: library.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
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

    var body: some View {
        List {
            if !tracks.isEmpty {
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
                ContentUnavailableView("Ancora vuota",
                                       systemImage: "music.note",
                                       description: Text("Aggiungi brani dal menu ··· accanto a ogni canzone."))
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
