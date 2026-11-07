import Foundation
import Combine
import CryptoKit

// MARK: - Modelli

struct PodcastShow: Identifiable, Codable, Hashable {
    var id: String { feedURL.isEmpty ? "itunes-\(collectionId ?? 0)" : feedURL }
    var title: String
    var author: String
    var artwork: String?
    var feedURL: String
    var collectionId: Int?
    var genre: String?

    var artworkURL: URL? { artwork.flatMap(URL.init(string:)) }
}

struct PodcastEpisode: Identifiable, Hashable {
    var id: String { audioURL }
    var title: String
    var date: Date?
    var duration: String?
    var summary: String
    var audioURL: String
    var artwork: String?

    /// Il brano da mettere nel player.
    func track(show: PodcastShow) -> Track {
        Track(id: "pod-" + PodcastEpisode.hash(audioURL),
              title: title,
              artist: show.title,
              album: show.title,
              duration: duration,
              thumbnail: artwork ?? show.artwork,
              mediaURL: audioURL)
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

struct LatestEpisode: Identifiable {
    var id: String { episode.id }
    let show: PodcastShow
    let episode: PodcastEpisode
}

struct PodcastFeed {
    var show: PodcastShow
    var description: String
    var episodes: [PodcastEpisode]
}

// MARK: - Catalogo (directory pubblica di Apple Podcasts)

enum PodcastDirectory {
    static func search(_ term: String) async throws -> [PodcastShow] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            .init(name: "media", value: "podcast"),
            .init(name: "term", value: term),
            .init(name: "country", value: "IT"),
            .init(name: "limit", value: "40")
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return parseLookup(data)
    }

    /// Classifica dei podcast più ascoltati in Italia.
    static func top() async throws -> [PodcastShow] {
        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/it/podcasts/top/50/podcasts.json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let results = ((obj?["feed"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return results.compactMap { r in
            guard let name = r["name"] as? String, let idStr = r["id"] as? String, let id = Int(idStr) else { return nil }
            let art = (r["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100", with: "600x600")
            let genre = ((r["genres"] as? [[String: Any]])?.first?["name"]) as? String
            return PodcastShow(title: name, author: (r["artistName"] as? String) ?? "",
                               artwork: art, feedURL: "", collectionId: id, genre: genre)
        }
    }

    /// Le voci della classifica non hanno il feed: lo si chiede al catalogo.
    static func resolveFeed(_ show: PodcastShow) async throws -> PodcastShow {
        guard show.feedURL.isEmpty, let id = show.collectionId else { return show }
        let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=podcast&country=IT")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard var found = parseLookup(data).first else { throw PodcastError.noFeed }
        if found.artwork == nil { found.artwork = show.artwork }
        return found
    }

    private static func parseLookup(_ data: Data) -> [PodcastShow] {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let results = (obj?["results"] as? [[String: Any]]) ?? []
        return results.compactMap { r in
            guard let feed = r["feedUrl"] as? String, !feed.isEmpty,
                  let name = (r["collectionName"] as? String) ?? (r["trackName"] as? String) else { return nil }
            return PodcastShow(title: name,
                               author: (r["artistName"] as? String) ?? "",
                               artwork: (r["artworkUrl600"] as? String) ?? (r["artworkUrl100"] as? String),
                               feedURL: feed,
                               collectionId: r["collectionId"] as? Int,
                               genre: r["primaryGenreName"] as? String)
        }
    }
}

enum PodcastError: LocalizedError {
    case noFeed, badFeed

    var errorDescription: String? {
        switch self {
        case .noFeed: return "Questo podcast non ha un feed pubblico."
        case .badFeed: return "Non riesco a leggere gli episodi di questo podcast."
        }
    }
}

// MARK: - Feed RSS

enum PodcastFeedLoader {
    static func load(_ show: PodcastShow) async throws -> PodcastFeed {
        let resolved = try await PodcastDirectory.resolveFeed(show)
        guard let url = URL(string: resolved.feedURL) else { throw PodcastError.noFeed }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("Armonia/1.0 (iPhone; podcast player)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let parser = RSSParser(data: data)
        guard parser.parse() else { throw PodcastError.badFeed }
        var s = resolved
        if s.artwork == nil { s.artwork = parser.channelImage }
        if s.author.isEmpty { s.author = parser.channelAuthor }
        if !parser.channelTitle.isEmpty && s.title.isEmpty { s.title = parser.channelTitle }
        let eps = parser.items.compactMap { i -> PodcastEpisode? in
            guard let audio = i.enclosure, !audio.isEmpty else { return nil }
            return PodcastEpisode(title: i.title.isEmpty ? "Episodio" : i.title,
                                  date: i.date, duration: normalizeDuration(i.duration),
                                  summary: stripHTML(i.summary), audioURL: audio, artwork: i.image)
        }
        return PodcastFeed(show: s, description: stripHTML(parser.channelDescription), episodes: eps)
    }

    /// "3725" o "01:02:05" → "1:02:05"
    static func normalizeDuration(_ d: String?) -> String? {
        guard let d = d?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        if !d.contains(":"), let secs = Double(d) { return formatTime(secs) }
        let parts = d.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return formatTime(parts.reduce(0) { $0 * 60 + $1 })
    }

    static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class RSSParser: NSObject, XMLParserDelegate {
    struct Item {
        var title = "", summary = "", duration: String?, enclosure: String?, image: String?, date: Date?
    }

    private let parser: XMLParser
    private(set) var channelTitle = ""
    private(set) var channelAuthor = ""
    private(set) var channelDescription = ""
    private(set) var channelImage: String?
    private(set) var items: [Item] = []

    private var current: Item?
    private var text = ""
    private var inImage = false

    private static let dateFormats: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz"].map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }
    }()

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> Bool { parser.parse() || !items.isEmpty }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        text = ""
        let el = (qName ?? name).lowercased()
        switch el {
        case "item": current = Item()
        case "enclosure":
            if current != nil, current?.enclosure == nil, let u = a["url"] {
                let type = a["type"] ?? ""
                if type.isEmpty || type.hasPrefix("audio") || type.hasPrefix("video") { current?.enclosure = u }
            }
        case "itunes:image":
            if let h = a["href"] {
                if current != nil { current?.image = h } else if channelImage == nil { channelImage = h }
            }
        case "image": if current == nil { inImage = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let el = (qName ?? name).lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != nil {
            switch el {
            case "title": if current!.title.isEmpty { current!.title = value }
            case "itunes:duration": current!.duration = value
            case "description", "content:encoded", "itunes:summary":
                if value.count > current!.summary.count { current!.summary = value }
            case "pubdate":
                current!.date = RSSParser.dateFormats.lazy.compactMap { $0.date(from: value) }.first
            case "item":
                items.append(current!)
                current = nil
            default: break
            }
        } else {
            switch el {
            case "title": if channelTitle.isEmpty && !inImage { channelTitle = value }
            case "itunes:author": if channelAuthor.isEmpty { channelAuthor = value }
            case "description", "itunes:summary":
                if value.count > channelDescription.count { channelDescription = value }
            case "url": if inImage && channelImage == nil { channelImage = value }
            case "image": inImage = false
            default: break
            }
        }
        text = ""
    }
}

// MARK: - Iscrizioni, episodi ascoltati e posizioni

@MainActor
final class PodcastStore: ObservableObject {
    static let shared = PodcastStore()

    @Published var subscriptions: [PodcastShow] = [] { didSet { save() } }
    @Published var played: Set<String> = [] { didSet { save() } }
    /// Ultimi episodi dei podcast seguiti (non salvati: si ricaricano).
    @Published var latest: [LatestEpisode] = []
    @Published var loadingLatest = false

    private let fileURL = URL.documentsDirectory.appendingPathComponent("podcast.json")
    private var loading = false

    private struct Snapshot: Codable {
        var subscriptions: [PodcastShow]
        var played: [String]
    }

    init() {
        loading = true
        if let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
            subscriptions = s.subscriptions
            played = Set(s.played)
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Snapshot(subscriptions: subscriptions, played: Array(played))
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: fileURL, options: .atomic) }
    }

    func isSubscribed(_ s: PodcastShow) -> Bool {
        subscriptions.contains { $0.id == s.id || ($0.collectionId != nil && $0.collectionId == s.collectionId) }
    }

    func toggleSubscription(_ s: PodcastShow) {
        if isSubscribed(s) {
            subscriptions.removeAll { $0.id == s.id || ($0.collectionId != nil && $0.collectionId == s.collectionId) }
            latest.removeAll { $0.show.id == s.id }
        } else {
            subscriptions.insert(s, at: 0)
            Task { await refreshLatest() }
        }
    }

    func isPlayed(_ t: Track) -> Bool { played.contains(t.id) }

    func setPlayed(_ t: Track, _ value: Bool) {
        if value { played.insert(t.id); PlaybackPositions.clear(t.id) } else { played.remove(t.id) }
    }

    /// Carica gli ultimi episodi di tutti i podcast seguiti.
    func refreshLatest() async {
        guard !loadingLatest, !subscriptions.isEmpty else { return }
        loadingLatest = true
        defer { loadingLatest = false }
        var all: [(PodcastShow, PodcastEpisode)] = []
        await withTaskGroup(of: [(PodcastShow, PodcastEpisode)].self) { group in
            for s in subscriptions {
                group.addTask {
                    guard let f = try? await PodcastFeedLoader.load(s) else { return [] }
                    return f.episodes.prefix(5).map { (f.show, $0) }
                }
            }
            for await r in group { all += r }
        }
        latest = all.sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }
            .prefix(40).map { LatestEpisode(show: $0.0, episode: $0.1) }
    }
}

/// Punto in cui si è interrotto l'ascolto di ogni episodio.
enum PlaybackPositions {
    static func get(_ id: String) -> Double { UserDefaults.standard.double(forKey: "pos-" + id) }
    static func set(_ id: String, _ t: Double) { UserDefaults.standard.set(t, forKey: "pos-" + id) }
    static func clear(_ id: String) { UserDefaults.standard.removeObject(forKey: "pos-" + id) }
}
