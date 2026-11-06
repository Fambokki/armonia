import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: String          // videoId di YouTube
    var title: String
    var artist: String
    var album: String?
    var duration: String?
    var thumbnail: String?

    /// Copertina ad alta risoluzione (le miniature di YT Music hanno la dimensione nell'URL).
    var artworkURL: URL? {
        guard let thumbnail else { return nil }
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
    case playlist(UUID)
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds)
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
