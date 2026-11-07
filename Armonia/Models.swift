import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: String          // videoId di YouTube, oppure "local-<nome file>" per i file importati
    var title: String
    var artist: String
    var album: String?
    var duration: String?
    var thumbnail: String?

    var isLocal: Bool { id.hasPrefix("local-") }

    /// Copertina ad alta risoluzione (le miniature di YT Music hanno la dimensione nell'URL).
    var artworkURL: URL? {
        guard let thumbnail else { return nil }
        if thumbnail.hasPrefix("local-art:") {
            return Storage.locals.appendingPathComponent(String(thumbnail.dropFirst("local-art:".count)))
        }
        var s = thumbnail
        if let r = s.range(of: "=w\\d+-h\\d+", options: .regularExpression) {
            s.replaceSubrange(r, with: "=w544-h544")
        }
        return URL(string: s)
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var tracks: [Track] = []
}

enum TrackSource: Hashable {
    case favorites
    case recents
    case downloads
    case locals
    case playlist(UUID)
}

// MARK: - Pagine di YouTube Music (artisti, album, playlist)

/// Una pagina da aprire: artista, album o playlist di YouTube Music.
struct BrowseTarget: Hashable {
    let browseId: String
    var params: String? = nil
    var title: String = ""
}

enum CollectionKind: String, Hashable {
    case artist, album, playlist, other
}

struct MusicCollection: Identifiable, Hashable {
    var id: String { browseId + (params ?? "") }
    let browseId: String
    var params: String?
    var title: String
    var subtitle: String
    var thumbnail: String?
    var kind: CollectionKind

    var target: BrowseTarget { BrowseTarget(browseId: browseId, params: params, title: title) }

    var artworkURL: URL? {
        Track(id: "", title: "", artist: "", thumbnail: thumbnail).artworkURL
    }
}

enum BrowseItem: Identifiable, Hashable {
    case track(Track)
    case collection(MusicCollection)

    var id: String {
        switch self {
        case .track(let t): return "t-" + t.id
        case .collection(let c): return "c-" + c.id
        }
    }
}

struct BrowseSection: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var items: [BrowseItem]
    var more: BrowseTarget?
    /// true = carosello orizzontale, false = lista verticale
    var isCarousel: Bool
    /// Righe per colonna nei caroselli di brani (es. "Scelte rapide" = 4).
    var rows: Int = 1

    var tracks: [Track] {
        items.compactMap { if case .track(let t) = $0 { return t } else { return nil } }
    }
}

struct BrowsePage {
    var title: String
    var subtitle: String
    var thumbnail: String?
    var kind: CollectionKind
    var sections: [BrowseSection]

    var artworkURL: URL? {
        Track(id: "", title: "", artist: "", thumbnail: thumbnail).artworkURL
    }

    /// Tutti i brani della pagina, nell'ordine in cui compaiono.
    var allTracks: [Track] {
        var seen = Set<String>()
        return sections.flatMap(\.tracks).filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Home

struct HomeChip: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let params: String?
}

enum FeedContinuation: Hashable {
    case legacy(String)   // ctoken nell'URL
    case modern(String)   // "continuation" nel corpo della richiesta
}

struct HomeFeed {
    var sections: [BrowseSection]
    var chips: [HomeChip]
    var continuation: FeedContinuation?
}

// MARK: - Cartelle dell'app

enum Storage {
    static let documents = URL.documentsDirectory
    static var downloads: URL { folder("Download") }
    static var locals: URL { folder("Locali") }

    private static func folder(_ name: String) -> URL {
        let u = documents.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }

    static func downloadURL(for id: String) -> URL {
        downloads.appendingPathComponent(id + ".m4a")
    }

    /// File da riprodurre senza rete, se esiste.
    static func playableFile(for t: Track) -> URL? {
        let u = t.isLocal
            ? locals.appendingPathComponent(String(t.id.dropFirst("local-".count)))
            : downloadURL(for: t.id)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func size(of folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds)
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
