import Foundation
import Combine
import SwiftUI

/// Libreria locale: preferiti, recenti, playlist, brani scaricati e file importati,
/// salvati in un file JSON sul telefono.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var favorites: [Track] = [] { didSet { favoriteIDs = Set(favorites.map(\.id)); save() } }
    @Published var recents: [Track] = [] { didSet { save() } }
    @Published var playlists: [Playlist] = [] { didSet { save() } }
    @Published var downloads: [Track] = [] { didSet { downloadedIDs = Set(downloads.map(\.id)); save() } }

    /// Insiemi per controlli istantanei (ogni riga di ogni lista li usa).
    private var favoriteIDs = Set<String>()
    private var downloadedIDs = Set<String>()
    @Published var locals: [Track] = [] { didSet { save() } }

    let fileURL = URL.documentsDirectory.appendingPathComponent("libreria.json")

    private struct Snapshot: Codable {
        var favorites: [Track] = []
        var recents: [Track] = []
        var playlists: [Playlist] = []
        var downloads: [Track] = []
        var locals: [Track] = []

        init(favorites: [Track], recents: [Track], playlists: [Playlist], downloads: [Track], locals: [Track]) {
            self.favorites = favorites
            self.recents = recents
            self.playlists = playlists
            self.downloads = downloads
            self.locals = locals
        }

        // Legge anche i file salvati dalle versioni precedenti (senza download e file locali).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favorites = try c.decodeIfPresent([Track].self, forKey: .favorites) ?? []
            recents = try c.decodeIfPresent([Track].self, forKey: .recents) ?? []
            playlists = try c.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
            downloads = try c.decodeIfPresent([Track].self, forKey: .downloads) ?? []
            locals = try c.decodeIfPresent([Track].self, forKey: .locals) ?? []
        }
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
        // Tiene solo i download il cui file esiste ancora.
        downloads = s.downloads.filter { Storage.playableFile(for: $0) != nil }
        locals = s.locals.filter { Storage.playableFile(for: $0) != nil }
    }

    private func save() {
        guard !isLoading else { return }
        let s = Snapshot(favorites: favorites, recents: recents, playlists: playlists,
                         downloads: downloads, locals: locals)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Preferiti e recenti

    func isFavorite(_ t: Track) -> Bool { favoriteIDs.contains(t.id) }

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

    // MARK: - Download e file locali

    func isDownloaded(_ t: Track) -> Bool {
        t.isLocal || downloadedIDs.contains(t.id)
    }

    func markDownloaded(_ t: Track) {
        guard !downloadedIDs.contains(t.id) else { return }
        downloads.insert(t, at: 0)
    }

    func removeDownload(_ t: Track) {
        Storage.removeDownloadFiles(for: t.id)
        downloads.removeAll { $0.id == t.id }
    }

    func removeAllDownloads() {
        for t in downloads { Storage.removeDownloadFiles(for: t.id) }
        downloads = []
    }

    func addLocal(_ t: Track) {
        locals.removeAll { $0.id == t.id }
        locals.insert(t, at: 0)
    }

    func removeLocal(_ t: Track) {
        if let u = Storage.playableFile(for: t) { try? FileManager.default.removeItem(at: u) }
        if let art = t.artworkURL, art.isFileURL { try? FileManager.default.removeItem(at: art) }
        locals.removeAll { $0.id == t.id }
        favorites.removeAll { $0.id == t.id }
        recents.removeAll { $0.id == t.id }
        for i in playlists.indices { playlists[i].tracks.removeAll { $0.id == t.id } }
    }

    // MARK: - Playlist

    @discardableResult
    func createPlaylist(_ name: String, tracks: [Track] = []) -> UUID {
        let p = Playlist(name: name.trimmingCharacters(in: .whitespaces), tracks: tracks)
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
        case .downloads: return downloads
        case .locals: return locals
        case .playlist(let id): return playlists.first { $0.id == id }?.tracks ?? []
        }
    }

    func title(for source: TrackSource) -> String {
        switch source {
        case .favorites: return "Preferiti"
        case .recents: return "Ascoltati di recente"
        case .downloads: return "Scaricati"
        case .locals: return "File importati"
        case .playlist(let id): return playlists.first { $0.id == id }?.name ?? "Playlist"
        }
    }

    func remove(at offsets: IndexSet, from source: TrackSource) {
        switch source {
        case .favorites: favorites.remove(atOffsets: offsets)
        case .recents: recents.remove(atOffsets: offsets)
        case .downloads:
            for t in offsets.map({ downloads[$0] }) { removeDownload(t) }
        case .locals:
            for t in offsets.map({ locals[$0] }) { removeLocal(t) }
        case .playlist(let id):
            guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
            playlists[i].tracks.remove(atOffsets: offsets)
        }
    }

    /// Salva un nuovo ordine dei brani nella playlist.
    func setOrder(_ tracks: [Track], in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks = tracks
    }

    func move(from source: IndexSet, to destination: Int, in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.move(fromOffsets: source, toOffset: destination)
    }
}
