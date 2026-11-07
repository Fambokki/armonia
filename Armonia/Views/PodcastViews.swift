import SwiftUI

/// Scheda Podcast: podcast seguiti, nuovi episodi, classifica italiana e ricerca.
struct PodcastsView: View {
    @EnvironmentObject private var store: PodcastStore

    @State private var query = ""
    @State private var results: [PodcastShow] = []
    @State private var searching = false
    @State private var top: [PodcastShow] = []
    @State private var error: String?

    var body: some View {
        List {
            if !query.isEmpty || !results.isEmpty {
                searchResults
            } else {
                if !store.subscriptions.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(store.subscriptions) { show in
                                    NavigationLink { PodcastDetailView(show: show) } label: {
                                        ShowCard(show: show)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparator(.hidden)
                    } header: {
                        sectionTitle("I tuoi podcast")
                    }

                    Section {
                        if store.latest.isEmpty {
                            HStack {
                                Spacer()
                                if store.loadingLatest { ProgressView() } else { Text("Nessun episodio").foregroundStyle(.secondary) }
                                Spacer()
                            }
                        }
                        ForEach(store.latest.prefix(15)) { item in
                            EpisodeRow(episode: item.episode, show: item.show, showName: true)
                        }
                    } header: {
                        sectionTitle("Nuovi episodi")
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Segui i tuoi podcast").font(.headline)
                            Text("Cercali qui sopra o scegline uno dalla classifica, poi tocca \"Segui\": i nuovi episodi compariranno qui.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    if top.isEmpty {
                        HStack {
                            Spacer()
                            if let error { Text(error).font(.caption).foregroundStyle(.secondary) } else { ProgressView() }
                            Spacer()
                        }
                    }
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, show in
                        NavigationLink { PodcastDetailView(show: show) } label: {
                            HStack(spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                ShowRowLabel(show: show)
                            }
                        }
                    }
                } header: {
                    sectionTitle("Classifica Italia")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Podcast")
        .withMiniPlayer()
        .searchable(text: $query, prompt: "Cerca un podcast")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: query) { _, v in if v.isEmpty { results = [] } }
        .task {
            if top.isEmpty { await loadTop() }
            if store.latest.isEmpty { await store.refreshLatest() }
        }
        .refreshable {
            await store.refreshLatest()
            await loadTop()
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if searching {
            HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
        }
        ForEach(results) { show in
            NavigationLink { PodcastDetailView(show: show) } label: { ShowRowLabel(show: show) }
        }
        if !searching && results.isEmpty && !query.isEmpty {
            Text("Premi Cerca sulla tastiera.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            results = (try? await PodcastDirectory.search(q)) ?? []
            searching = false
        }
    }

    private func loadTop() async {
        do {
            top = try await PodcastDirectory.top()
            error = nil
        } catch {
            if top.isEmpty { self.error = "Classifica non disponibile." }
        }
    }
}

struct ShowCard: View {
    let show: PodcastShow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: show.artworkURL, corner: 10).frame(width: 130, height: 130)
            Text(show.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 130)
    }
}

struct ShowRowLabel: View {
    let show: PodcastShow

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: show.artworkURL, corner: 8).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(show.title).lineLimit(2)
                Text([show.author, show.genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Pagina di un podcast con tutti gli episodi.
struct PodcastDetailView: View {
    let show: PodcastShow

    @EnvironmentObject private var store: PodcastStore
    @EnvironmentObject private var player: PlayerManager
    @State private var feed: PodcastFeed?
    @State private var error: String?
    @State private var expanded = false
    @State private var hidePlayed = false

    private var current: PodcastShow { feed?.show ?? show }

    private var episodes: [PodcastEpisode] {
        let all = feed?.episodes ?? []
        guard hidePlayed else { return all }
        return all.filter { !store.played.contains($0.track(show: current).id) }
    }

    var body: some View {
        List {
            header.listRowSeparator(.hidden)

            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if feed == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(episodes) { ep in
                        EpisodeRow(episode: ep, show: current, showName: false)
                    }
                } header: {
                    HStack {
                        Text("\(feed?.episodes.count ?? 0) episodi").textCase(nil)
                        Spacer()
                        Button(hidePlayed ? "Mostra tutti" : "Nascondi ascoltati") { hidePlayed.toggle() }
                            .font(.caption).textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .withMiniPlayer()
        .task { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(url: current.artworkURL, corner: 14)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
            VStack(spacing: 4) {
                Text(current.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                Text(current.author).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button {
                    store.toggleSubscription(current)
                } label: {
                    Label(store.isSubscribed(current) ? "Segui già" : "Segui",
                          systemImage: store.isSubscribed(current) ? "checkmark" : "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    if let first = feed?.episodes.first { player.play([first.track(show: current)]) }
                } label: {
                    Label("Ultimo episodio", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(feed?.episodes.isEmpty ?? true)
            }
            .controlSize(.large)

            if let d = feed?.description, !d.isEmpty {
                Text(d)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func load() async {
        do {
            feed = try await PodcastFeedLoader.load(show)
            error = nil
        } catch {
            if feed == nil { self.error = error.localizedDescription }
        }
    }
}

/// Riga di un episodio: data, durata, descrizione, avanzamento e azioni.
struct EpisodeRow: View {
    let episode: PodcastEpisode
    let show: PodcastShow
    let showName: Bool

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var store: PodcastStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    private var track: Track { episode.track(show: show) }

    var body: some View {
        let t = track
        let isCurrent = player.current?.id == t.id
        let played = store.played.contains(t.id)
        let position = PlaybackPositions.get(t.id)

        HStack(alignment: .top, spacing: 12) {
            if showName {
                ArtworkView(url: t.artworkURL, corner: 8).frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let d = episode.date {
                        Text(d, format: .dateTime.day().month(.abbreviated).year())
                    }
                    if showName { Text("· " + show.title).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(2)

                if !episode.summary.isEmpty {
                    Text(episode.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                HStack(spacing: 8) {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    if played {
                        Label("Ascoltato", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    } else if position > 15, let total = durationSeconds {
                        ProgressView(value: min(position / total, 1)).frame(width: 60)
                        Text("-" + formatTime(max(total - position, 0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else if let d = episode.duration {
                        Text(d).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    DownloadBadge(track: t)
                }
                .padding(.top, 2)
            }
            Menu { actions(t, played: played) } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 36)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent { player.togglePlay() } else { player.play([t]) }
        }
        .contextMenu { actions(t, played: played) }
    }

    private var durationSeconds: Double? {
        guard let d = episode.duration else { return nil }
        let v = d.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
        return v > 0 ? v : nil
    }

    @ViewBuilder
    private func actions(_ t: Track, played: Bool) -> some View {
        Button { player.playNext(t) } label: { Label("Riproduci dopo", systemImage: "text.insert") }
        Button { player.addToQueue(t) } label: { Label("Aggiungi in coda", systemImage: "text.append") }
        Button { store.setPlayed(t, !played) } label: {
            played ? Label("Segna come da ascoltare", systemImage: "circle")
                   : Label("Segna come ascoltato", systemImage: "checkmark.circle")
        }
        Divider()
        if library.isDownloaded(t) {
            Button(role: .destructive) { library.removeDownload(t) } label: { Label("Rimuovi download", systemImage: "trash") }
        } else if downloads.isQueued(t) {
            Button { downloads.cancel(t) } label: { Label("Annulla download", systemImage: "xmark.circle") }
        } else {
            Button { downloads.download([t]) } label: { Label("Scarica episodio", systemImage: "arrow.down.circle") }
        }
    }
}
