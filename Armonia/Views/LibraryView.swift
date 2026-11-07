import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var showSpotify = false
    @State private var showSettings = false
    @State private var showFilePicker = false
    @State private var importing: (done: Int, total: Int)?
    @State private var importMessage: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TrackListScreen(source: .favorites)
                } label: {
                    Label("Preferiti", systemImage: "heart.fill")
                        .badge(library.favorites.count)
                }
                NavigationLink {
                    TrackListScreen(source: .downloads)
                } label: {
                    Label("Scaricati", systemImage: "arrow.down.circle.fill")
                        .badge(library.downloads.count)
                }
                NavigationLink {
                    TrackListScreen(source: .locals)
                } label: {
                    Label("File importati", systemImage: "internaldrive")
                        .badge(library.locals.count)
                }
                NavigationLink {
                    TrackListScreen(source: .recents)
                } label: {
                    Label("Ascoltati di recente", systemImage: "clock")
                }
            }

            if downloads.activeCount > 0 {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Download in corso: \(downloads.activeCount)")
                        Spacer()
                        Button("Annulla") { downloads.cancelAll() }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section("Playlist") {
                Button {
                    newName = ""
                    showNewPlaylist = true
                } label: {
                    Label("Nuova playlist", systemImage: "plus")
                }
                ForEach(library.playlists) { p in
                    NavigationLink {
                        TrackListScreen(source: .playlist(p.id))
                    } label: {
                        Label(p.name, systemImage: "music.note.list")
                            .badge(p.tracks.count)
                    }
                }
                .onDelete { library.deletePlaylists(at: $0) }
            }
        }
        .navigationTitle("Libreria")
        .navigationDestination(for: BrowseTarget.self) { BrowsePageView(target: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = ""; showNewPlaylist = true } label: {
                        Label("Nuova playlist", systemImage: "music.note.list")
                    }
                    Button { showSpotify = true } label: {
                        Label("Importa da Spotify", systemImage: "square.and.arrow.down")
                    }
                    Button { showFilePicker = true } label: {
                        Label("Importa file audio (FLAC, ALAC…)", systemImage: "waveform.badge.plus")
                    }
                    Divider()
                    ShareLink(item: library.fileURL) {
                        Label("Esporta libreria (JSON)", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let importing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Importo i file… \(importing.done)/\(importing.total)")
                }
                .padding(12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 90)
            }
        }
        .alert("Nuova playlist", isPresented: $showNewPlaylist) {
            TextField("Nome", text: $newName)
            Button("Crea") {
                if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.createPlaylist(newName)
                }
            }
            Button("Annulla", role: .cancel) {}
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showSpotify) { SpotifyImportView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            importFiles(urls)
        }
    }

    private func importFiles(_ urls: [URL]) {
        importing = (0, urls.count)
        Task {
            var ok = 0
            var failed: [String] = []
            for (i, u) in urls.enumerated() {
                do {
                    let t = try await LocalImporter.importFile(u)
                    library.addLocal(t)
                    ok += 1
                } catch {
                    failed.append(u.lastPathComponent)
                }
                importing = (i + 1, urls.count)
            }
            importing = nil
            importMessage = failed.isEmpty
                ? "Importati \(ok) file. Li trovi in \"File importati\"."
                : "Importati \(ok) file. Non riusciti: \(failed.joined(separator: ", "))"
        }
    }
}

/// Ordinamenti disponibili nelle liste di brani.
enum TrackSort: String, CaseIterable, Identifiable {
    case custom, recentFirst, title, artist, album, duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .custom: return "Personalizzato"
        case .recentFirst: return "Aggiunti di recente"
        case .title: return "Titolo"
        case .artist: return "Artista"
        case .album: return "Album"
        case .duration: return "Durata"
        }
    }

    var symbol: String {
        switch self {
        case .custom: return "hand.draw"
        case .recentFirst: return "clock.arrow.circlepath"
        case .title: return "textformat"
        case .artist: return "person"
        case .album: return "square.stack"
        case .duration: return "timer"
        }
    }

    /// Ha senso invertire l'ordine (A→Z / Z→A, breve→lungo…).
    var canReverse: Bool { self != .custom && self != .recentFirst }
}

private func seconds(_ d: String?) -> Int {
    (d ?? "").split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
}

func sortTracks(_ tracks: [Track], by sort: TrackSort, ascending: Bool) -> [Track] {
    let cmp: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
    var out: [Track]
    switch sort {
    case .custom: return tracks
    case .recentFirst: return tracks.reversed()
    case .title: out = tracks.sorted { cmp($0.title, $1.title) }
    case .artist: out = tracks.sorted { $0.artist == $1.artist ? cmp($0.title, $1.title) : cmp($0.artist, $1.artist) }
    case .album: out = tracks.sorted { ($0.album ?? "") == ($1.album ?? "") ? cmp($0.title, $1.title) : cmp($0.album ?? "~", $1.album ?? "~") }
    case .duration: out = tracks.sorted { seconds($0.duration) < seconds($1.duration) }
    }
    return ascending ? out : out.reversed()
}

struct TrackListScreen: View {
    let source: TrackSource

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @State private var showRename = false
    @State private var newName = ""
    @State private var sort: TrackSort = .custom
    @State private var ascending = true
    @State private var filter = ""
    @State private var editMode: EditMode = .inactive

    private var allTracks: [Track] { library.tracks(for: source) }

    /// Brani come li vede l'utente: ordinati e filtrati.
    private var tracks: [Track] {
        var list = sortTracks(allTracks, by: sort, ascending: ascending)
        let q = filter.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
                    || ($0.album ?? "").localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    private var playlistID: UUID? {
        if case .playlist(let id) = source { return id }
        return nil
    }

    private var sortKey: String {
        switch source {
        case .favorites: return "sort-favorites"
        case .recents: return "sort-recents"
        case .downloads: return "sort-downloads"
        case .locals: return "sort-locals"
        case .playlist(let id): return "sort-\(id.uuidString)"
        }
    }

    /// Il trascinamento manuale funziona solo nelle playlist, in ordine personalizzato e senza filtro.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard let id = playlistID, sort == .custom, filter.isEmpty else { return nil }
        let store = library
        return { from, to in store.move(from: from, to: to, in: id) }
    }

    private var emptyText: String {
        switch source {
        case .downloads: return "Scarica brani, album o playlist dal menu ··· per ascoltarli senza internet."
        case .locals: return "Importa i tuoi file FLAC, ALAC o MP3 dal pulsante + nella Libreria."
        default: return "Aggiungi brani dal menu ··· accanto a ogni canzone."
        }
    }

    var body: some View {
        let shown = tracks
        List {
            if !allTracks.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            player.play(shown)
                        } label: {
                            Label("Riproduci", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        Button {
                            player.play(shown.shuffled())
                        } label: {
                            Label("Casuale", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    HStack {
                        sortMenu
                        Spacer()
                        switch source {
                        case .downloads:
                            Text("\(allTracks.count) brani · \(formatBytes(Storage.size(of: Storage.downloads)))")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .locals:
                            Text("\(allTracks.count) file · \(formatBytes(Storage.size(of: Storage.locals)))")
                                .font(.footnote).foregroundStyle(.secondary)
                        default:
                            DownloadAllButton(tracks: allTracks)
                                .font(.subheadline)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }

            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t) { player.play(shown, startAt: i) }
            }
            .onDelete { offsets in
                // Gli indici si riferiscono alla lista mostrata: si cancella per identità del brano.
                let ids = Set(offsets.map { shown[$0].id })
                let original = IndexSet(allTracks.indices.filter { ids.contains(allTracks[$0].id) })
                library.remove(at: original, from: source)
            }
            .onMove(perform: moveAction)
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(library.title(for: source))
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Cerca in questa lista")
        .overlay {
            if allTracks.isEmpty {
                ContentUnavailableView("Ancora vuota", systemImage: "music.note", description: Text(emptyText))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .toolbar {
            if playlistID != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        newName = library.title(for: source)
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    Button(editMode.isEditing ? "Fine" : "Modifica") {
                        if !editMode.isEditing && sort != .custom { setSort(.custom) }
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
        }
        .onAppear(perform: loadSort)
        .alert("Rinomina playlist", isPresented: $showRename) {
            TextField("Nome", text: $newName)
            Button("Salva") {
                if let id = playlistID, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.renamePlaylist(id, to: newName)
                }
            }
            Button("Annulla", role: .cancel) {}
        }
    }

    // MARK: - Ordinamento

    private var sortMenu: some View {
        Menu {
            Picker("Ordina per", selection: Binding(get: { sort }, set: { setSort($0) })) {
                ForEach(TrackSort.allCases) { s in
                    Label(s.label, systemImage: s.symbol).tag(s)
                }
            }
            if sort.canReverse {
                Button {
                    ascending.toggle()
                    saveSort()
                } label: {
                    Label(ascending ? "Inverti (Z→A)" : "Inverti (A→Z)", systemImage: "arrow.up.arrow.down")
                }
            }
            if let id = playlistID, sort != .custom {
                Divider()
                Button {
                    library.setOrder(sortTracks(allTracks, by: sort, ascending: ascending), in: id)
                    setSort(.custom)
                } label: {
                    Label("Salva come ordine della playlist", systemImage: "checkmark.circle")
                }
            }
        } label: {
            Label(sort == .custom ? "Ordina" : sort.label + (sort.canReverse && !ascending ? " ↓" : ""),
                  systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
        }
    }

    private func setSort(_ s: TrackSort) {
        if s != sort { ascending = true }
        sort = s
        if s != .custom { editMode = .inactive }
        saveSort()
    }

    private func loadSort() {
        let raw = UserDefaults.standard.string(forKey: sortKey) ?? ""
        let parts = raw.split(separator: "|")
        sort = parts.first.flatMap { TrackSort(rawValue: String($0)) } ?? .custom
        ascending = parts.count < 2 || parts[1] != "desc"
    }

    private func saveSort() {
        UserDefaults.standard.set("\(sort.rawValue)|\(ascending ? "asc" : "desc")", forKey: sortKey)
    }
}
