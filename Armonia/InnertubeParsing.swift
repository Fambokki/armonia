import Foundation

// Lettura delle pagine di YouTube Music: risultati di ricerca, artisti, album, playlist.
// Il JSON di Innertube cambia spesso forma, quindi qui si cercano i "mattoni" noti
// (scaffali, caroselli, righe) ovunque si trovino, invece di seguire un percorso fisso.

extension JSON {
    private static let shelfKeys: Set<String> = [
        "musicShelfRenderer", "musicPlaylistShelfRenderer", "musicCarouselShelfRenderer",
        "gridRenderer", "musicCardShelfRenderer"
    ]

    static func sections(_ root: Any, carousels: Bool) -> [BrowseSection] {
        var out: [BrowseSection] = []
        walk(root, carousels: carousels, into: &out)
        return out.filter { !$0.items.isEmpty }
    }

    private static func walk(_ node: Any, carousels: Bool, into out: inout [BrowseSection]) {
        if let d = node as? [String: Any] {
            for key in d.keys.sorted() {
                let v = d[key]!
                if shelfKeys.contains(key), let shelf = v as? [String: Any] {
                    if let s = section(kind: key, shelf, carousels: carousels) { out.append(s) }
                } else if key != "header" && key != "frameworkUpdates" && key != "responseContext" {
                    walk(v, carousels: carousels, into: &out)
                }
            }
        } else if let a = node as? [Any] {
            for v in a { walk(v, carousels: carousels, into: &out) }
        }
    }

    private static func section(kind: String, _ s: [String: Any], carousels: Bool) -> BrowseSection? {
        switch kind {
        case "musicShelfRenderer", "musicPlaylistShelfRenderer":
            var more: BrowseTarget?
            if let be = (s["bottomEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any] {
                more = target(be, title: text(s["title"]) ?? "")
            } else if let runs = (s["title"] as? [String: Any])?["runs"] as? [[String: Any]],
                      let be = (runs.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any] {
                more = target(be, title: text(s["title"]) ?? "")
            }
            return BrowseSection(title: text(s["title"]) ?? "",
                                 items: items(s["contents"]),
                                 more: more, isCarousel: false)

        case "musicCarouselShelfRenderer":
            let h = (s["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
            let title = text(h?["title"]) ?? ""
            var more: BrowseTarget?
            if let be = firstValue(h?["moreContentButton"] ?? [String: Any](), key: "browseEndpoint") as? [String: Any] {
                more = target(be, title: title)
            }
            var rows = 1
            if let n = s["numItemsPerColumn"] as? String, let v = Int(n) { rows = v }
            else if let v = s["numItemsPerColumn"] as? Int { rows = v }
            return BrowseSection(title: title, items: items(s["contents"]), more: more,
                                 isCarousel: carousels, rows: max(1, rows))

        case "gridRenderer":
            let h = (s["header"] as? [String: Any])?["gridHeaderRenderer"] as? [String: Any]
            return BrowseSection(title: text(h?["title"]) ?? "", items: items(s["items"]), more: nil, isCarousel: false)

        case "musicCardShelfRenderer":
            var list: [BrowseItem] = []
            if let top = cardItem(s) { list.append(top) }
            list += items(s["contents"])
            return BrowseSection(title: "Risultato principale", items: list, more: nil, isCarousel: false)

        default:
            return nil
        }
    }

    private static func items(_ any: Any?) -> [BrowseItem] {
        guard let arr = any as? [[String: Any]] else { return [] }
        var out: [BrowseItem] = []
        var seen = Set<String>()
        for e in arr {
            var item: BrowseItem?
            if let r = e["musicResponsiveListItemRenderer"] as? [String: Any] {
                item = responsiveItem(r)
            } else if let r = e["musicTwoRowItemRenderer"] as? [String: Any] {
                item = twoRowItem(r)
            }
            if let item, seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }

    private static func responsiveItem(_ r: [String: Any]) -> BrowseItem? {
        if let t = parseListItem(r) { return .track(t) }
        guard let be = (r["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
              let id = be["browseId"] as? String else { return nil }
        let cols: [[String: Any]] = ((r["flexColumns"] as? [[String: Any]]) ?? []).compactMap {
            ($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any]
        }
        guard let title = cols.first.flatMap({ text($0) }) else { return nil }
        let subtitle = cols.count > 1 ? (text(cols[1]) ?? "") : ""
        return .collection(MusicCollection(browseId: id, params: be["params"] as? String,
                                           title: title, subtitle: subtitle,
                                           thumbnail: thumbnail(r["thumbnail"]),
                                           kind: kind(be, id: id)))
    }

    private static func twoRowItem(_ r: [String: Any]) -> BrowseItem? {
        guard let title = text(r["title"]) else { return nil }
        let subtitle = text(r["subtitle"]) ?? ""
        let thumb = thumbnail(r["thumbnailRenderer"])
        let nav = r["navigationEndpoint"] as? [String: Any]
        if let be = nav?["browseEndpoint"] as? [String: Any], let id = be["browseId"] as? String {
            return .collection(MusicCollection(browseId: id, params: be["params"] as? String,
                                               title: title, subtitle: subtitle,
                                               thumbnail: thumb, kind: kind(be, id: id)))
        }
        if let vid = (nav?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
            return .track(Track(id: vid, title: title, artist: artistFrom(subtitle), thumbnail: thumb))
        }
        // I "Mix" a volte aprono direttamente la riproduzione: li si apre come playlist.
        if let pid = (nav?["watchPlaylistEndpoint"] as? [String: Any])?["playlistId"] as? String {
            return .collection(MusicCollection(browseId: "VL" + pid, params: nil, title: title,
                                               subtitle: subtitle, thumbnail: thumb, kind: .playlist))
        }
        return nil
    }

    // MARK: - Home

    static func homeFeed(_ json: [String: Any]) -> HomeFeed {
        var chips: [HomeChip] = []
        collect(json, key: "chipCloudChipRenderer") { c in
            guard let title = text(c["text"]) else { return }
            let be = (c["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
            chips.append(HomeChip(title: title, params: be?["params"] as? String))
        }
        var cont: FeedContinuation?
        if let d = firstValue(json, key: "nextContinuationData") as? [String: Any],
           let t = d["continuation"] as? String {
            cont = .legacy(t)
        } else {
            collect(json, key: "continuationItemRenderer") { r in
                if cont == nil, let cmd = firstValue(r, key: "continuationCommand") as? [String: Any],
                   let t = cmd["token"] as? String {
                    cont = .modern(t)
                }
            }
        }
        return HomeFeed(sections: sections(json, carousels: true), chips: chips, continuation: cont)
    }

    private static func cardItem(_ s: [String: Any]) -> BrowseItem? {
        guard let title = text(s["title"]),
              let runs = (s["title"] as? [String: Any])?["runs"] as? [[String: Any]],
              let nav = runs.first?["navigationEndpoint"] as? [String: Any] else { return nil }
        let subtitle = text(s["subtitle"]) ?? ""
        let thumb = thumbnail(s["thumbnail"])
        if let be = nav["browseEndpoint"] as? [String: Any], let id = be["browseId"] as? String {
            return .collection(MusicCollection(browseId: id, params: be["params"] as? String,
                                               title: title, subtitle: subtitle,
                                               thumbnail: thumb, kind: kind(be, id: id)))
        }
        if let vid = (nav["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
            return .track(Track(id: vid, title: title, artist: artistFrom(subtitle), thumbnail: thumb))
        }
        return nil
    }

    private static func artistFrom(_ subtitle: String) -> String {
        let types: Set<String> = ["Brano", "Song", "Video", "Singolo", "Single", "EP", "Album"]
        return subtitle.components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !types.contains($0) } ?? ""
    }

    private static func target(_ be: [String: Any], title: String) -> BrowseTarget? {
        guard let id = be["browseId"] as? String else { return nil }
        return BrowseTarget(browseId: id, params: be["params"] as? String, title: title)
    }

    private static func kind(_ be: [String: Any], id: String) -> CollectionKind {
        let pageType = firstValue(be, key: "pageType") as? String ?? ""
        if pageType.contains("ARTIST") || pageType.contains("USER_CHANNEL") { return .artist }
        if pageType.contains("ALBUM") || pageType.contains("AUDIOBOOK") { return .album }
        if pageType.contains("PLAYLIST") { return .playlist }
        return kind(forId: id)
    }

    static func kind(forId id: String) -> CollectionKind {
        if id.hasPrefix("MPRE") { return .album }
        if id.hasPrefix("UC") { return .artist }
        if id.hasPrefix("VL") || id.hasPrefix("PL") || id.hasPrefix("RD") || id.hasPrefix("OLAK") { return .playlist }
        return .other
    }

    // MARK: - Pagina intera

    static func page(_ json: [String: Any], fallbackTitle: String, browseId: String) -> BrowsePage {
        let headerKeys = ["musicResponsiveHeaderRenderer", "musicImmersiveHeaderRenderer",
                          "musicVisualHeaderRenderer", "musicDetailHeaderRenderer",
                          "musicEditablePlaylistDetailHeaderRenderer"]
        var header: [String: Any]?
        for k in headerKeys {
            if let h = firstValue(json, key: k) as? [String: Any] { header = h; break }
        }
        if let inner = header?["header"] as? [String: Any],
           let h = firstValue(inner, key: "musicResponsiveHeaderRenderer") as? [String: Any] {
            header = h
        }

        let title = text(header?["title"]) ?? fallbackTitle
        let strapline = text(header?["straplineTextOne"])
        let subtitle = strapline ?? text(header?["subtitle"]) ?? ""
        let thumb = thumbnail(header?["thumbnail"]) ?? header.flatMap { thumbnail($0) }
        let kind = kind(forId: browseId)

        var secs = sections(json, carousels: true)
        if kind != .artist {
            // Le righe degli album spesso non hanno copertina né artista: si prendono dall'intestazione.
            let artist = strapline ?? subtitle.components(separatedBy: " • ").dropFirst().first ?? ""
            for i in secs.indices {
                secs[i].items = secs[i].items.map { item in
                    guard case .track(var t) = item else { return item }
                    if t.thumbnail == nil { t.thumbnail = thumb }
                    if t.artist.isEmpty { t.artist = artist }
                    if kind == .album && t.album == nil { t.album = title }
                    return .track(t)
                }
            }
        }
        return BrowsePage(title: title, subtitle: subtitle, thumbnail: thumb, kind: kind, sections: secs)
    }
}
