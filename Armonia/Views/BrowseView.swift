import SwiftUI

/// Pagina di un artista, album o playlist di YouTube Music.
struct BrowsePageView: View {
    let target: BrowseTarget

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var page: BrowsePage?
    @State private var error: String?
    @State private var savedMessage: String?

    var body: some View {
        List {
            if let page {
                header(page)
                    .listRowSeparator(.hidden)
                ForEach(page.sections) { section in
                    SectionView(section: section, isSearch: false)
                }
            } else if let error {
                ContentUnavailableView("Pagina non disponibile", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
                    .listRowSeparator(.hidden)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.top, 40)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(page?.title ?? target.title)
        .withMiniPlayer()
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(savedMessage ?? "", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func load() async {
        do {
            page = try await Innertube.shared.browse(target)
            error = nil
        } catch {
            if page == nil { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func header(_ page: BrowsePage) -> some View {
        let tracks = page.allTracks
        VStack(spacing: 14) {
            ArtworkView(url: page.artworkURL, corner: page.kind == .artist ? 120 : 12)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            VStack(spacing: 4) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if !page.subtitle.isEmpty {
                    Text(page.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Button { player.play(tracks) } label: {
                        Label("Riproduci", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    Button { player.playShuffled(tracks) } label: {
                        Label("Casuale", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if page.kind != .artist {
                    HStack(spacing: 20) {
                        Button {
                            library.createPlaylist(page.title, tracks: tracks)
                            savedMessage = "Salvata nella Libreria come playlist."
                        } label: {
                            Label("Salva in Libreria", systemImage: "plus.circle")
                        }
                        DownloadAllButton(tracks: tracks)
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// Una sezione di risultati: lista di brani, elenco di artisti/album o carosello orizzontale.
struct SectionView: View {
    let section: BrowseSection
    let isSearch: Bool

    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        Section {
            if section.isCarousel && section.rows > 1 {
                // "Scelte rapide": colonne di brani che scorrono in orizzontale.
                let gridRows = Array(repeating: GridItem(.fixed(56), spacing: 6), count: section.rows)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: gridRows, spacing: 16) {
                        ForEach(section.items) { item in
                            QuickPickCell(item: item, siblings: section.tracks)
                                .frame(width: 300, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
            } else if section.isCarousel {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(section.items) { item in
                            CarouselCard(item: item, siblings: section.tracks)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
            } else {
                ForEach(section.items) { item in
                    switch item {
                    case .track(let t):
                        TrackRow(track: t) {
                            if isSearch {
                                player.startRadio(from: t)
                            } else {
                                let list = section.tracks
                                player.play(list, startAt: list.firstIndex(of: t) ?? 0)
                            }
                        }
                    case .collection(let c):
                        CollectionRow(collection: c)
                    }
                }
            }
        } header: {
            if !section.title.isEmpty {
                HStack {
                    Text(section.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if let more = section.more {
                        NavigationLink(value: more) {
                            Text("Vedi tutti").font(.subheadline)
                        }
                    }
                }
                .textCase(nil)
            }
        }
    }
}

/// Riga compatta usata nelle "Scelte rapide" della Home.
struct QuickPickCell: View {
    let item: BrowseItem
    let siblings: [Track]

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        switch item {
        case .track(let t):
            HStack(spacing: 10) {
                Button {
                    player.startRadio(from: t)
                } label: {
                    HStack(spacing: 10) {
                        ArtworkView(url: t.artworkURL, corner: 4).frame(width: 50, height: 50)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.subheadline).lineLimit(1)
                                .foregroundStyle(player.current?.id == t.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Button { player.playNext(t) } label: { Label("Riproduci dopo", systemImage: "text.insert") }
                    Button { player.addToQueue(t) } label: { Label("Aggiungi in coda", systemImage: "text.append") }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 44)
                }
            }
        case .collection(let c):
            Button { nav.open(c.target) } label: {
                HStack(spacing: 10) {
                    ArtworkView(url: c.artworkURL, corner: c.kind == .artist ? 25 : 4).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.subheadline).lineLimit(1)
                        Text(c.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct CollectionRow: View {
    let collection: MusicCollection

    var body: some View {
        NavigationLink(value: collection.target) {
            HStack(spacing: 12) {
                ArtworkView(url: collection.artworkURL, corner: collection.kind == .artist ? 24 : 6)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.title).lineLimit(1)
                    Text(collection.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct CarouselCard: View {
    let item: BrowseItem
    let siblings: [Track]

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        switch item {
        case .collection(let c):
            Button { nav.open(c.target) } label: {
                card(url: c.artworkURL, title: c.title, subtitle: c.subtitle, round: c.kind == .artist)
            }
            .buttonStyle(.plain)
        case .track(let t):
            Button {
                player.play(siblings, startAt: siblings.firstIndex(of: t) ?? 0)
            } label: {
                card(url: t.artworkURL, title: t.title, subtitle: t.artist, round: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func card(url: URL?, title: String, subtitle: String, round: Bool) -> some View {
        VStack(alignment: round ? .center : .leading, spacing: 6) {
            ArtworkView(url: url, corner: round ? 70 : 8)
                .frame(width: 140, height: 140)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 140)
    }
}
