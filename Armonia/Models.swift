import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: String          // videoId di YouTube, oppure "local-<nome file>" per i file importati
    var title: String
    var artist: String
    var album: String?
    var duration: String?
    var thumbnail: String?
    /// Indirizzo diretto dell'audio (episodi dei podcast). nil per i brani di YouTube Music.
    var mediaURL: String? = nil

    var isLocal: Bool { id.hasPrefix("local-") }
    var isPodcast: Bool { id.hasPrefix("pod-") }

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

// MARK: - Qualità audio

enum AudioQuality: String, CaseIterable, Identifiable {
    case low, normal, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Risparmio dati"
        case .normal: return "Normale"
        case .high: return "Alta"
        }
    }

    var detail: String {
        switch self {
        case .low: return "AAC · circa 48 kbps"
        case .normal: return "AAC · circa 128 kbps"
        case .high: return "Opus · circa 160 kbps"
        }
    }

    /// Legge l'impostazione salvata (con conversione dalla vecchia opzione sì/no).
    static func stored(_ key: String, legacyLowKey: String) -> AudioQuality {
        if let raw = UserDefaults.standard.string(forKey: key), let q = AudioQuality(rawValue: raw) { return q }
        return UserDefaults.standard.bool(forKey: legacyLowKey) ? .low : .normal
    }
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

    /// Cartella di cache per i brani in alta qualità (Opus) ascoltati in streaming.
    static var opusCache: URL {
        let u = URL.cachesDirectory.appendingPathComponent("Opus", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }

    static func downloadURL(for id: String, ext: String = "m4a") -> URL {
        downloads.appendingPathComponent(id + "." + ext)
    }

    /// File scaricato di un brano (AAC .m4a oppure Opus .caf), se esiste.
    static let downloadExtensions = ["caf", "m4a", "mp3", "aac", "mp4"]

    static func downloadedFile(for id: String) -> URL? {
        for ext in downloadExtensions {
            let u = downloadURL(for: id, ext: ext)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func removeDownloadFiles(for id: String, except keep: String? = nil) {
        for ext in downloadExtensions where ext != keep {
            try? FileManager.default.removeItem(at: downloadURL(for: id, ext: ext))
        }
    }

    /// File da riprodurre senza rete, se esiste.
    static func playableFile(for t: Track) -> URL? {
        if t.isLocal {
            let u = locals.appendingPathComponent(String(t.id.dropFirst("local-".count)))
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        return downloadedFile(for: t.id)
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
