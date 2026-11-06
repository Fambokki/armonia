import Foundation
import Combine
import SwiftUI

/// Libreria locale: preferiti, ascolti recenti e playlist, salvati in un file JSON sul telefono.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var favorites: [Track] = [] { didSet { save() } }
    @Published var recents: [Track] = [] { didSet { save() } }
    @Published var playlists: [Playlist] = [] { didSet { save() } }

    let fileURL = URL.documentsDirectory.appendingPathComponent("libreria.json")

    private struct Snapshot: Codable {
        var favorites: [Track]
        var recents: [Track]
        var playlists: [Playlist]
    }

    private var isLoading = false

    init() { load() }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = s.favorites
        recents = s.recents
        playlists = s.playlists
    }

    private func save() {
        guard !isLoading else { return }
        let s = Snapshot(favorites: favorites, recents: recents, playlists: playlists)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Preferiti e recenti

    func isFavorite(_ t: Track) -> Bool { favorites.contains { $0.id == t.id } }

    func toggleFavorite(_ t: Track) {
        if isFavorite(t) {
            favorites.removeAll { $0.id == t.id }
        } else {
            favorites.insert(t, at: 0)
        }
    }

    func addRecent(_ t: Track) {
        var list = recents
        list.removeAll { $0.id == t.id }
        list.insert(t, at: 0)
        if list.count > 50 { list.removeLast(list.count - 50) }
        recents = list
    }

    // MARK: - Playlist

    @discardableResult
    func createPlaylist(_ name: String) -> UUID {
        let p = Playlist(name: name.trimmingCharacters(in: .whitespaces))
        playlists.append(p)
        return p.id
    }

    func add(_ t: Track, to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.append(t)
    }

    func deletePlaylists(at offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
    }

    // MARK: - Accesso generico per le liste

    func tracks(for source: TrackSource) -> [Track] {
        switch source {
        case .favorites: return favorites
        case .recents: return recents
        case .playlist(let id): return playlists.first { $0.id == id }?.tracks ?? []
        }
    }

    func title(for source: TrackSource) -> String {
        switch source {
        case .favorites: return "Preferiti"
        case .recents: return "Ascoltati di recente"
        case .playlist(let id): return playlists.first { $0.id == id }?.name ?? "Playlist"
        }
    }

    func remove(at offsets: IndexSet, from source: TrackSource) {
        switch source {
        case .favorites: favorites.remove(atOffsets: offsets)
        case .recents: recents.remove(atOffsets: offsets)
        case .playlist(let id):
            guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
            playlists[i].tracks.remove(atOffsets: offsets)
        }
    }

    func move(from source: IndexSet, to destination: Int, in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.move(fromOffsets: source, toOffset: destination)
    }
}
