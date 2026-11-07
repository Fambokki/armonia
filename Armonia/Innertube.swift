import Foundation

// Client minimale per l'API interna di YouTube Music ("Innertube").
// È la parte fragile dell'app. I client usati per l'audio si possono aggiornare
// senza reinstallare: all'avvio l'app legge `clients.json` dal repository GitHub
// (vedi `remoteConfigURL`); se non lo trova usa quelli scritti qui sotto.

struct StreamInfo: Sendable {
    let url: URL
    let userAgent: String
    /// Dimensione in byte (nota solo per i file diretti, non per HLS).
    var contentLength: Int64?
    var isHLS = false
    /// Descrizione della qualità, es. "AAC 128 kbps".
    var label = ""
}

enum InnertubeError: LocalizedError {
    case http(Int)
    case unplayable(String)
    case notDownloadable

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Il server ha risposto con errore \(code)."
        case .unplayable(let reason): return "Brano non riproducibile: \(reason)"
        case .notDownloadable: return "Questo brano è disponibile solo in streaming."
        }
    }
}

private struct PlayerClient: @unchecked Sendable {
    let name: String
    let version: String
    let nameId: String
    let userAgent: String
    let extra: [String: Any]

    init(name: String, version: String, nameId: String, userAgent: String, extra: [String: Any]) {
        self.name = name
        self.version = version
        self.nameId = nameId
        self.userAgent = userAgent
        self.extra = extra
    }

    /// Legge un client dal file clients.json.
    init?(json d: [String: Any]) {
        guard let name = d["name"] as? String,
              let version = d["version"] as? String,
              let userAgent = d["userAgent"] as? String else { return nil }
        let nameId: String
        if let s = d["nameId"] as? String { nameId = s }
        else if let n = d["nameId"] as? Int { nameId = String(n) }
        else { return nil }
        self.init(name: name, version: version, nameId: nameId, userAgent: userAgent,
                  extra: (d["extra"] as? [String: Any]) ?? [:])
    }
}

private struct CachedStream {
    let info: StreamInfo
    let date: Date
}

actor Innertube {
    static let shared = Innertube()

    // Configurazione aggiornabile senza reinstallare l'app.
    private let remoteConfigURL = URL(string: "https://raw.githubusercontent.com/Fambokki/armonia/main/clients.json")!

    // Versione del client web di YouTube Music (ricerca, radio).
    private var musicVersion = "1.20260707.12.00"
    private let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    // Client usati per ottenere l'audio, provati in ordine (valori di riserva).
    // VISIONOS oggi non richiede token né decifrazione delle firme.
    private var playerClients: [PlayerClient] = [
        PlayerClient(
            name: "VISIONOS",
            version: "1.02",
            nameId: "101",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            extra: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"]
        ),
        PlayerClient(
            name: "IOS",
            version: "21.26.4",
            nameId: "5",
            userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"]
        ),
    ]
    private var configLoaded = false

    /// Scarica clients.json (al massimo una volta per avvio). Se fallisce restano i valori di riserva.
    private func loadRemoteConfigIfNeeded() async {
        guard !configLoaded else { return }
        configLoaded = true
        var req = URLRequest(url: remoteConfigURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let v = obj["musicVersion"] as? String, !v.isEmpty { musicVersion = v }
        let clients = ((obj["playerClients"] as? [[String: Any]]) ?? []).compactMap(PlayerClient.init(json:))
        if !clients.isEmpty { playerClients = clients }
    }

    /// Verifica che il link audio risponda davvero (YouTube a volte dà il link ma poi risponde 403).
    /// Restituisce il codice HTTP e, se noto, la dimensione totale del file.
    private func probe(_ url: URL, userAgent: String) async -> (code: Int, total: Int64?) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return (-1, nil) }
        var total: Int64?
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/") {
            total = Int64(cr[cr.index(after: slash)...])
        }
        return (http.statusCode, total)
    }

    // MARK: - Ricerca

    func search(_ query: String) async throws -> [Track] {
        await loadRemoteConfigIfNeeded()
        let body: [String: Any] = [
            "context": musicContext(),
            "query": query,
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA==" // filtro "Brani"
        ]
        let json = try await post("https://music.youtube.com/youtubei/v1/search?prettyPrint=false",
                                  body: body, headers: musicHeaders())
        var out: [Track] = []
        var seen = Set<String>()
        JSON.collect(json, key: "musicResponsiveListItemRenderer") { r in
            if let t = JSON.parseListItem(r), !seen.contains(t.id) {
                seen.insert(t.id)
                out.append(t)
            }
        }
        return out
    }

    // MARK: - Radio (brani simili)

    func radio(for videoId: String) async throws -> [Track] {
        let body: [String: Any] = [
            "context": musicContext(),
            "videoId": videoId,
            "playlistId": "RDAMVM" + videoId,
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true
        ]
        let json = try await post("https://music.youtube.com/youtubei/v1/next?prettyPrint=false",
                                  body: body, headers: musicHeaders())
        var out: [Track] = []
        var seen = Set<String>()
        JSON.collect(json, key: "playlistPanelVideoRenderer") { r in
            guard let id = r["videoId"] as? String, !seen.contains(id),
                  let title = JSON.text(r["title"]) else { return }
            seen.insert(id)
            let byline = JSON.text(r["longBylineText"]) ?? JSON.text(r["shortBylineText"]) ?? ""
            let parts = byline.components(separatedBy: " • ")
            out.append(Track(id: id,
                             title: title,
                             artist: parts.first ?? "",
                             album: parts.count > 2 ? parts[1] : nil,
                             duration: JSON.text(r["lengthText"]),
                             thumbnail: JSON.thumbnail(r["thumbnail"])))
        }
        return out
    }

    // MARK: - Flusso audio

    /// - lowQuality: sceglie il bitrate più basso (risparmio dati).
    /// - forDownload: esclude HLS, che non si può salvare come file singolo.
    func stream(for videoId: String, lowQuality: Bool = false, forDownload: Bool = false) async throws -> StreamInfo {
        let cacheKey = videoId + (lowQuality ? "-low" : "") + (forDownload ? "-dl" : "")
        if let cached = streamCache[cacheKey], Date().timeIntervalSince(cached.date) < 3600 {
            return cached.info
        }
        await loadRemoteConfigIfNeeded()

        struct Candidate { let url: URL; let label: String; let isHLS: Bool; let length: Int64? }

        var reasons: [String] = []
        for c in playerClients {
            var client: [String: Any] = ["clientName": c.name, "clientVersion": c.version, "hl": "it", "gl": "IT"]
            for (k, v) in c.extra { client[k] = v }
            if let visitorData { client["visitorData"] = visitorData }

            let body: [String: Any] = [
                "context": ["client": client],
                "videoId": videoId,
                "contentCheckOk": true,
                "racyCheckOk": true
            ]
            let headers = [
                "User-Agent": c.userAgent,
                "X-YouTube-Client-Name": c.nameId,
                "X-YouTube-Client-Version": c.version,
                "Origin": "https://www.youtube.com"
            ]
            do {
                let json = try await post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
                                          body: body, headers: headers)
                let ps = json["playabilityStatus"] as? [String: Any]
                let status = ps?["status"] as? String ?? "?"
                guard status == "OK" else {
                    reasons.append("\(c.name): \((ps?["reason"] as? String) ?? status)")
                    continue
                }
                guard let sd = json["streamingData"] as? [String: Any] else {
                    reasons.append("\(c.name): nessun flusso")
                    continue
                }

                // Candidati in ordine: audio AAC (m4a), video+audio mp4, HLS.
                let bitrate: ([String: Any]) -> Int = { ($0["bitrate"] as? Int) ?? 0 }
                let kbps: ([String: Any]) -> Int = { f in
                    let avg = (f["averageBitrate"] as? Int) ?? bitrate(f)
                    return Int((Double(avg) / 1000).rounded())
                }
                let length: ([String: Any]) -> Int64? = { f in
                    (f["contentLength"] as? String).flatMap { Int64($0) }
                }
                let adaptive = (sd["adaptiveFormats"] as? [[String: Any]]) ?? []
                let muxed = (sd["formats"] as? [[String: Any]]) ?? []
                var candidates: [Candidate] = []
                candidates += adaptive
                    .filter { (($0["mimeType"] as? String) ?? "").hasPrefix("audio/mp4") }
                    .sorted { lowQuality ? bitrate($0) < bitrate($1) : bitrate($0) > bitrate($1) }
                    .compactMap { f in
                        (f["url"] as? String).flatMap(URL.init(string:)).map {
                            Candidate(url: $0, label: "AAC \(kbps(f)) kbps", isHLS: false, length: length(f))
                        }
                    }
                candidates += muxed
                    .filter { (($0["mimeType"] as? String) ?? "").hasPrefix("video/mp4") }
                    .compactMap { f in
                        (f["url"] as? String).flatMap(URL.init(string:)).map {
                            Candidate(url: $0, label: "AAC (da video)", isHLS: false, length: length(f))
                        }
                    }
                if !forDownload, let h = sd["hlsManifestUrl"] as? String, let u = URL(string: h) {
                    candidates.append(Candidate(url: u, label: "HLS", isHLS: true, length: nil))
                }

                guard !candidates.isEmpty else {
                    reasons.append("\(c.name): flusso protetto")
                    continue
                }
                var codes: [Int] = []
                for cand in candidates.prefix(3) {
                    let (code, total) = await probe(cand.url, userAgent: c.userAgent)
                    if code == 200 || code == 206 {
                        let info = StreamInfo(url: cand.url, userAgent: c.userAgent,
                                              contentLength: total ?? cand.length,
                                              isHLS: cand.isHLS, label: cand.label)
                        streamCache[cacheKey] = CachedStream(info: info, date: Date())
                        return info
                    }
                    codes.append(code)
                }
                reasons.append("\(c.name): audio rifiutato (\(codes.map { $0 < 0 ? "rete" : String($0) }.joined(separator: ",")))")
            } catch {
                reasons.append("\(c.name): \(error.localizedDescription)")
            }
        }
        if forDownload && reasons.isEmpty { throw InnertubeError.notDownloadable }
        throw InnertubeError.unplayable(reasons.isEmpty ? "nessun client disponibile" : reasons.joined(separator: " · "))
    }

    // MARK: - Ricerca completa (artisti, album, brani, playlist)

    func searchAll(_ query: String) async throws -> [BrowseSection] {
        await loadRemoteConfigIfNeeded()
        let body: [String: Any] = ["context": musicContext(), "query": query]
        let json = try await post("https://music.youtube.com/youtubei/v1/search?prettyPrint=false",
                                  body: body, headers: musicHeaders())
        return JSON.sections(json, carousels: false)
    }

    // MARK: - Pagine (artista, album, playlist)

    func browse(_ target: BrowseTarget) async throws -> BrowsePage {
        await loadRemoteConfigIfNeeded()
        var body: [String: Any] = ["context": musicContext(), "browseId": target.browseId]
        if let p = target.params { body["params"] = p }
        let json = try await post("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false",
                                  body: body, headers: musicHeaders())
        return JSON.page(json, fallbackTitle: target.title, browseId: target.browseId)
    }

    // MARK: - Rete

    private func musicContext() -> [String: Any] {
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": musicVersion, "hl": "it", "gl": "IT"]
        if let visitorData { client["visitorData"] = visitorData }
        return ["client": client]
    }

    private func musicHeaders() -> [String: String] {
        [
            "User-Agent": webUA,
            "Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
            "X-YouTube-Client-Name": "67",
            "X-YouTube-Client-Version": musicVersion
        ]
    }

    private func post(_ urlString: String, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("it-IT,it;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let visitorData { req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InnertubeError.http(code) }
        let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if visitorData == nil,
           let ctx = obj["responseContext"] as? [String: Any],
           let v = ctx["visitorData"] as? String {
            visitorData = v
        }
        return obj
    }
}

// MARK: - Utility per leggere il JSON di Innertube

enum JSON {
    /// Visita in profondità tutti gli oggetti con una certa chiave (resiste ai cambi di struttura).
    static func collect(_ node: Any, key: String, _ visit: ([String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            for (k, v) in d {
                if k == key, let inner = v as? [String: Any] {
                    visit(inner)
                } else {
                    collect(v, key: key, visit)
                }
            }
        } else if let a = node as? [Any] {
            for v in a { collect(v, key: key, visit) }
        }
    }

    static func firstValue(_ node: Any, key: String) -> Any? {
        if let d = node as? [String: Any] {
            if let v = d[key] { return v }
            for v in d.values {
                if let f = firstValue(v, key: key) { return f }
            }
        } else if let a = node as? [Any] {
            for v in a {
                if let f = firstValue(v, key: key) { return f }
            }
        }
        return nil
    }

    static func text(_ any: Any?) -> String? {
        guard let d = any as? [String: Any] else { return nil }
        if let s = d["simpleText"] as? String { return s }
        if let runs = d["runs"] as? [[String: Any]] {
            let s = runs.compactMap { $0["text"] as? String }.joined()
            return s.isEmpty ? nil : s
        }
        return nil
    }

    static func thumbnail(_ any: Any?) -> String? {
        guard let any,
              let arr = firstValue(any, key: "thumbnails") as? [[String: Any]] else { return nil }
        return arr.last?["url"] as? String
    }

    static func parseListItem(_ r: [String: Any]) -> Track? {
        let columns: [[String: Any]] = ((r["flexColumns"] as? [[String: Any]]) ?? []).compactMap {
            ($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any]
        }
        guard let first = columns.first, let title = text(first) else { return nil }

        var videoId = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String
        if videoId == nil, let runs = first["runs"] as? [[String: Any]] {
            let nav = runs.first?["navigationEndpoint"] as? [String: Any]
            videoId = (nav?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
        }
        guard let id = videoId else { return nil }

        var parts: [String] = []
        if columns.count > 1, let s = text(columns[1]) {
            parts = s.components(separatedBy: " • ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let f = parts.first, ["Brano", "Song", "Video", "Episodio", "Episode"].contains(f) {
            parts.removeFirst()
        }

        let isDuration: (String) -> Bool = { $0.range(of: "^\\d+:\\d{2}(:\\d{2})?$", options: .regularExpression) != nil }
        var duration: String?
        if let last = parts.last, isDuration(last) {
            duration = last
            parts.removeLast()
        }
        if duration == nil, let fixed = r["fixedColumns"] as? [[String: Any]] {
            let t = (fixed.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"]
            if let s = text(t), isDuration(s) { duration = s }
        }

        return Track(id: id,
                     title: title,
                     artist: parts.first ?? "",
                     album: parts.count > 1 ? parts[1] : nil,
                     duration: duration,
                     thumbnail: thumbnail(r["thumbnail"]))
    }
}
