import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    @State private var query = ""
    @State private var results: [Track] = []
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

            if query.isEmpty && results.isEmpty && !library.recents.isEmpty {
                Section("Ascoltati di recente") {
                    ForEach(Array(library.recents.prefix(15).enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t) { player.play(Array(library.recents.prefix(15)), startAt: i) }
                    }
                }
            } else {
                ForEach(results) { t in
                    TrackRow(track: t) { player.startRadio(from: t) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Cerca")
        .searchable(text: $query, prompt: "Brani, artisti, album")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty {
                searchTask?.cancel()
                results = []
                error = nil
            }
        }
        .overlay {
            if query.isEmpty && results.isEmpty && library.recents.isEmpty {
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
                let found = try await Innertube.shared.search(q)
                guard !Task.isCancelled else { return }
                results = found
                if found.isEmpty { error = "Nessun risultato." }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Ricerca non riuscita: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }
}
