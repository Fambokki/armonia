import Foundation

// Client minimale per l'API interna di YouTube Music ("Innertube").
// È la parte fragile dell'app: se YouTube cambia qualcosa, di solito basta
// aggiornare le versioni dei client qui sotto e ricompilare.

struct StreamInfo: Sendable {
    let url: URL
    let userAgent: String
}

enum InnertubeError: LocalizedError {
    case http(Int)
    case unplayable(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Il server ha risposto con errore \(code)."
        case .unplayable(let reason): return "Brano non riproducibile: \(reason)"
        }
    }
}

private struct PlayerClient: @unchecked Sendable {
    let name: String
    let version: String
    let nameId: String
    let userAgent: String
    let extra: [String: Any]
}

private struct CachedStream {
    let info: StreamInfo
    let date: Date
}

actor Innertube {
    static let shared = Innertube()

    // Versione del client web di YouTube Music (ricerca, radio).
    private let musicVersion = "1.20251015.01.00"
    private let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    // Client usati per ottenere l'audio, provati in ordine.
    private let playerClients: [PlayerClient] = [
        PlayerClient(
            name: "IOS",
            version: "20.10.4",
            nameId: "5",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"]
        ),
        PlayerClient(
            name: "ANDROID_VR",
            version: "1.62.27",
            nameId: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"]
        ),
    ]

    private var visitorData: String?
    private var streamCache: [String: CachedStream] = [:]

    // MARK: - Ricerca

    func search(_ query: String) async throws -> [Track] {
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

    func stream(for videoId: String) async throws -> StreamInfo {
        if let cached = streamCache[videoId], Date().timeIntervalSince(cached.date) < 3600 {
            return cached.info
        }
        var lastReason = "nessun client disponibile"
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
                    lastReason = (ps?["reason"] as? String) ?? status
                    continue
                }
                guard let sd = json["streamingData"] as? [String: Any] else {
                    lastReason = "nessun flusso"
                    continue
                }
                // Preferisce l'audio AAC (m4a), che AVPlayer riproduce nativamente.
                let formats = (sd["adaptiveFormats"] as? [[String: Any]]) ?? []
                let audio = formats
                    .filter { (($0["mimeType"] as? String) ?? "").hasPrefix("audio/mp4") && $0["url"] is String }
                    .sorted { (($0["bitrate"] as? Int) ?? 0) > (($1["bitrate"] as? Int) ?? 0) }
                var chosen: URL?
                if let s = audio.first?["url"] as? String { chosen = URL(string: s) }
                if chosen == nil, let h = sd["hlsManifestUrl"] as? String { chosen = URL(string: h) }
                guard let url = chosen else {
                    lastReason = "flusso protetto (\(c.name))"
                    continue
                }
                let info = StreamInfo(url: url, userAgent: c.userAgent)
                streamCache[videoId] = CachedStream(info: info, date: Date())
                return info
            } catch {
                lastReason = error.localizedDescription
            }
        }
        throw InnertubeError.unplayable(lastReason)
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
