import SwiftUI

/// Schermata iniziale in stile YouTube Music / Spotify:
/// saluto, categorie, scorciatoie personali, mix basati sugli ascolti e caroselli di YouTube Music.
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    @State private var feed: HomeFeed?
    @State private var baseChips: [HomeChip] = []
    @State private var selectedChip: HomeChip?
    @State private var mixes: [BrowseSection] = []
    @State private var mixSeedIDs: [String] = []
    @State private var error: String?
    @State private var loadingMore = false

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<13: return "Buongiorno"
        case 13..<18: return "Buon pomeriggio"
        default: return "Buonasera"
        }
    }

    var body: some View {
        List {
            if !baseChips.isEmpty {
                chipsRow
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
            }

            if selectedChip == nil {
                if !shortcutTiles.isEmpty {
                    quickGrid
                        .listRowSeparator(.hidden)
                }
                if library.recents.count >= 3 {
                    SectionView(section: BrowseSection(title: "Ascoltati di recente",
                                                       items: library.recents.prefix(15).map { .track($0) },
                                                       more: nil, isCarousel: true),
                                isSearch: false)
                }
                ForEach(mixes) { SectionView(section: $0, isSearch: false) }
            }

            if let feed {
                ForEach(feed.sections) { section in
                    SectionView(section: section, isSearch: false)
                }
                if feed.continuation != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await loadMore() } }
                }
            } else if let error {
                VStack(spacing: 10) {
                    Text("Non riesco a caricare i consigli di YouTube Music.")
                        .font(.subheadline)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Riprova") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowSeparator(.hidden)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 30)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(greeting)
        .navigationDestination(for: BrowseTarget.self) { BrowsePageView(target: $0) }
        .task {
            if feed == nil { await load() }
        }
        .refreshable {
            mixSeedIDs = []
            await load()
        }
    }

    // MARK: - Categorie (Rilassati, Energia, Allenamento…)

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(baseChips) { chip in
                    let selected = selectedChip == chip
                    Button {
                        selectedChip = selected ? nil : chip
                        Task { await load() }
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12)),
                                        in: Capsule())
                            .foregroundStyle(selected ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Scorciatoie (griglia 2 colonne come Spotify)

    private enum Tile: Identifiable {
        case favorites, downloads
        case playlist(Playlist)
        case track(Track)

        var id: String {
            switch self {
            case .favorites: return "fav"
            case .downloads: return "dl"
            case .playlist(let p): return "p-\(p.id)"
            case .track(let t): return "t-\(t.id)"
            }
        }
    }

    private var shortcutTiles: [Tile] {
        var tiles: [Tile] = []
        if !library.favorites.isEmpty { tiles.append(.favorites) }
        if !library.downloads.isEmpty { tiles.append(.downloads) }
        tiles += library.playlists.prefix(4).map { .playlist($0) }
        for t in library.recents where tiles.count < 8 { tiles.append(.track(t)) }
        return Array(tiles.prefix(8))
    }

    private var quickGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(shortcutTiles) { tile in
                switch tile {
                case .favorites:
                    NavigationLink { TrackListScreen(source: .favorites) } label: {
                        tileLabel(title: "Preferiti", symbol: "heart.fill", url: nil)
                    }
                    .buttonStyle(.plain)
                case .downloads:
                    NavigationLink { TrackListScreen(source: .downloads) } label: {
                        tileLabel(title: "Scaricati", symbol: "arrow.down.circle.fill", url: nil)
                    }
                    .buttonStyle(.plain)
                case .playlist(let p):
                    NavigationLink { TrackListScreen(source: .playlist(p.id)) } label: {
                        tileLabel(title: p.name, symbol: "music.note.list", url: p.tracks.first?.artworkURL)
                    }
                    .buttonStyle(.plain)
                case .track(let t):
                    Button { player.startRadio(from: t) } label: {
                        tileLabel(title: t.title, symbol: "music.note", url: t.artworkURL)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tileLabel(title: String, symbol: String, url: URL?) -> some View {
        HStack(spacing: 10) {
            Group {
                if let url {
                    ArtworkView(url: url, corner: 0)
                } else {
                    LinearGradient(colors: [Color(red: 1, green: 0.22, blue: 0.37), Color(red: 0.48, green: 0.16, blue: 0.78)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Image(systemName: symbol).foregroundStyle(.white) }
                }
            }
            .frame(width: 56, height: 56)
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(height: 56)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Caricamento

    private func load() async {
        error = nil
        Task { await loadMixes() }
        do {
            let f = try await Innertube.shared.home(params: selectedChip?.params)
            feed = f
            if selectedChip == nil && !f.chips.isEmpty { baseChips = f.chips }
        } catch {
            if feed == nil { self.error = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard !loadingMore, let c = feed?.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let more = try? await Innertube.shared.homeMore(c) else {
            feed?.continuation = nil
            return
        }
        feed?.sections += more.sections
        feed?.continuation = more.sections.isEmpty ? nil : more.continuation
    }

    /// "Mix per te": brani simili all'ultimo ascoltato e a un preferito.
    private func loadMixes() async {
        var seeds: [Track] = []
        if let r = library.recents.first(where: { !$0.isLocal }) { seeds.append(r) }
        if let f = library.favorites.first(where: { !$0.isLocal && $0.id != seeds.first?.id }) { seeds.append(f) }
        let ids = seeds.map(\.id)
        guard !seeds.isEmpty, ids != mixSeedIDs else { return }
        var out: [BrowseSection] = []
        for (i, seed) in seeds.enumerated() {
            guard let tracks = try? await Innertube.shared.radio(for: seed.id) else { continue }
            let list = tracks.filter { $0.id != seed.id }.prefix(i == 0 ? 16 : 12)
            guard !list.isEmpty else { continue }
            out.append(BrowseSection(title: i == 0 ? "Perché hai ascoltato \(seed.title)" : "Simili a \(seed.title)",
                                     items: list.map { .track($0) },
                                     more: nil, isCarousel: true, rows: i == 0 ? 4 : 1))
        }
        mixes = out
        mixSeedIDs = ids
    }
}
