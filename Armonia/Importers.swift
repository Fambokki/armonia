import Foundation
import AVFoundation
import UIKit

// MARK: - File audio dal telefono (FLAC, ALAC, MP3, AAC, WAV…)

enum LocalImporter {
    /// Copia il file nell'app, legge titolo/artista/album/copertina e restituisce il brano.
    static func importFile(_ source: URL) async throws -> Track {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        let dest = Storage.locals.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: dest)

        let asset = AVURLAsset(url: dest)
        var title: String?
        var artist: String?
        var album: String?
        var artworkName: String?

        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in metadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: title = try? await item.load(.stringValue)
            case .commonKeyArtist: artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: album = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                if artworkName == nil, let data = try? await item.load(.dataValue), let img = UIImage(data: data),
                   let jpg = img.jpegData(compressionQuality: 0.85) {
                    let art = name + ".jpg"
                    try? jpg.write(to: Storage.locals.appendingPathComponent(art))
                    artworkName = art
                }
            default: break
            }
        }

        // Se mancano i tag, prova a usare il nome del file ("Artista - Titolo").
        let base = source.deletingPathExtension().lastPathComponent
        if title == nil || title?.isEmpty == true {
            let parts = base.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist == nil { artist = parts[0].trimmingCharacters(in: .whitespaces) }
                title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            } else {
                title = base
            }
        }

        var duration: String?
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            duration = formatTime(d.seconds)
        }

        return Track(id: "local-" + name,
                     title: title ?? base,
                     artist: artist ?? "Sconosciuto",
                     album: album,
                     duration: duration,
                     thumbnail: artworkName.map { "local-art:" + $0 })
    }
}

// MARK: - Playlist di Spotify

struct ImportedSong: Hashable {
    let title: String
    let artist: String
}

enum SpotifyImportError: LocalizedError {
    case invalidLink
    case unreadable

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "Link non valido. Incolla il link di una playlist o di un album di Spotify."
        case .unreadable: return "Non riesco a leggere la playlist. Se è privata rendila pubblica, oppure usa il file CSV di Exportify."
        }
    }
}

enum SpotifyImporter {
    /// Legge titolo e brani di una playlist o album pubblico dalla pagina "embed" di Spotify.
    static func fetch(link: String) async throws -> (name: String, songs: [ImportedSong]) {
        let pattern = "(playlist|album)[/:]([A-Za-z0-9]{10,})"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
              let typeRange = Range(m.range(at: 1), in: link),
              let idRange = Range(m.range(at: 2), in: link) else { throw SpotifyImportError.invalidLink }
        let type = String(link[typeRange]), id = String(link[idRange])

        var req = URLRequest(url: URL(string: "https://open.spotify.com/embed/\(type)/\(id)")!, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8),
              let start = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let jsonData = String(html[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) else { throw SpotifyImportError.unreadable }

        guard let entity = JSON.firstValue(json, key: "entity") as? [String: Any],
              let list = entity["trackList"] as? [[String: Any]], !list.isEmpty else { throw SpotifyImportError.unreadable }
        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Da Spotify"
        let songs = list.compactMap { t -> ImportedSong? in
            guard let title = t["title"] as? String else { return nil }
            return ImportedSong(title: title, artist: (t["subtitle"] as? String) ?? "")
        }
        return (name, songs)
    }

    /// Legge un CSV esportato da Exportify (exportify.app) o simili: colonne "Track Name" e "Artist Name(s)".
    static func parseCSV(_ text: String) -> [ImportedSong] {
        let rows = csvRows(text)
        guard let header = rows.first?.map({ $0.lowercased() }) else { return [] }
        let titleCol = header.firstIndex { $0 == "track name" || $0 == "name" || $0 == "title" || $0 == "titolo" }
        let artistCol = header.firstIndex { $0.hasPrefix("artist name") || $0 == "artist" || $0 == "artists" || $0 == "artista" }
        guard let titleCol else { return [] }
        return rows.dropFirst().compactMap { r in
            guard r.indices.contains(titleCol), !r[titleCol].isEmpty else { return nil }
            var artist = artistCol.flatMap { r.indices.contains($0) ? r[$0] : nil } ?? ""
            artist = artist.replacingOccurrences(of: ";", with: ", ")
            return ImportedSong(title: r[titleCol], artist: artist)
        }
    }

    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func find(_ s: ImportedSong, index: Int) async -> (Int, Track?) {
        let firstArtist = s.artist.components(separatedBy: ",").first ?? s.artist
        let found = try? await Innertube.shared.search("\(s.title) \(firstArtist)")
        return (index, found?.first)
    }

    /// Cerca ogni brano su YouTube Music (6 ricerche alla volta) e restituisce gli abbinamenti nell'ordine originale.
    static func match(_ songs: [ImportedSong], progress: @escaping @MainActor (Int) -> Void) async -> [Track?] {
        var results = [Track?](repeating: nil, count: songs.count)
        var done = 0
        await withTaskGroup(of: (Int, Track?).self) { group in
            var next = 0
            while next < min(6, songs.count) {
                let i = next
                next += 1
                group.addTask { await find(songs[i], index: i) }
            }
            for await (i, t) in group {
                results[i] = t
                done += 1
                await progress(done)
                if next < songs.count {
                    let j = next
                    next += 1
                    group.addTask { await find(songs[j], index: j) }
                }
            }
        }
        return results
    }
}
