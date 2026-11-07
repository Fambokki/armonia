import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    @State private var query = ""
    @State private var sections: [BrowseSection] = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if query.isEmpty && sections.isEmpty && !library.recents.isEmpty {
                Section("Ascoltati di recente") {
                    let recents = Array(library.recents.prefix(15))
                    ForEach(Array(recents.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t) { player.play(recents, startAt: i) }
                    }
                }
            } else {
                ForEach(sections) { s in
                    SectionView(section: s, isSearch: true)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Cerca")
        .withMiniPlayer()
        .searchable(text: $query, prompt: "Brani, artisti, album")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty {
                searchTask?.cancel()
                sections = []
                error = nil
            }
        }
        .overlay {
            if query.isEmpty && sections.isEmpty && library.recents.isEmpty {
                ContentUnavailableView("Cerca la tua musica",
                                       systemImage: "music.magnifyingglass",
                                       description: Text("Tocca un brano per ascoltarlo: la coda si riempie da sola con brani simili."))
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        error = nil
        searchTask = Task {
            do {
                var found = try await Innertube.shared.searchAll(q)
                // Se la ricerca completa non dà nulla di utile, ripiega sui soli brani.
                if found.allSatisfy({ $0.items.isEmpty }) {
                    let songs = try await Innertube.shared.search(q)
                    found = songs.isEmpty ? [] : [BrowseSection(title: "Brani", items: songs.map { .track($0) },
                                                                more: nil, isCarousel: false)]
                }
                guard !Task.isCancelled else { return }
                sections = found
                if found.isEmpty { error = "Nessun risultato." }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Ricerca non riuscita: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }
}
