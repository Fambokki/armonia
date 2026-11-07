import SwiftUI
import UniformTypeIdentifiers

/// Importa una playlist di Spotify: link pubblico oppure file CSV di Exportify.
struct SpotifyImportView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case input
        case matching(done: Int, total: Int)
        case review
    }

    @State private var link = ""
    @State private var phase: Phase = .input
    @State private var error: String?
    @State private var showCSVPicker = false
    @State private var name = ""
    @State private var songs: [ImportedSong] = []
    @State private var matches: [Track?] = []

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .input: inputForm
                case .matching(let done, let total): matchingView(done: done, total: total)
                case .review: reviewForm
                }
            }
            .navigationTitle("Importa da Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showCSVPicker,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    error = "Non riesco a leggere il file."
                    return
                }
                let parsed = SpotifyImporter.parseCSV(text)
                guard !parsed.isEmpty else {
                    error = "Nel file non ho trovato le colonne \"Track Name\" e \"Artist Name(s)\"."
                    return
                }
                start(name: url.deletingPathExtension().lastPathComponent, songs: parsed)
            }
        }
    }

    // MARK: - Fasi

    @ViewBuilder
    private var inputForm: some View {
        Section {
            TextField("https://open.spotify.com/playlist/…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Importa dal link") { fetchLink() }
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Link della playlist")
        } footer: {
            Text("In Spotify: ··· sulla playlist → Condividi → Copia link. La playlist deve essere pubblica. Dal link si leggono fino a circa 100 brani.")
        }

        Section {
            Button("Scegli file CSV…") { showCSVPicker = true }
        } header: {
            Text("Playlist lunghe o private")
        } footer: {
            Text("Da computer o telefono apri exportify.app, accedi con Spotify ed esporta la playlist in CSV, poi salvala nell'app File e sceglila qui.")
        }

        if let error {
            Section { Text(error).foregroundStyle(.orange) }
        }
    }

    private func matchingView(done: Int, total: Int) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cerco i brani su YouTube Music…")
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done) di \(total)").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var reviewForm: some View {
        let found = matches.compactMap { $0 }
        Section {
            TextField("Nome playlist", text: $name)
            Button("Crea playlist con \(found.count) brani") {
                library.createPlaylist(name.isEmpty ? "Da Spotify" : name, tracks: found)
                dismiss()
            }
            .disabled(found.isEmpty)
        } footer: {
            Text("Trovati \(found.count) brani su \(songs.count).")
        }

        let missing = songs.indices.filter { matches[$0] == nil }
        if !missing.isEmpty {
            Section("Non trovati") {
                ForEach(missing, id: \.self) { i in
                    VStack(alignment: .leading) {
                        Text(songs[i].title)
                        Text(songs[i].artist).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section("Abbinamenti") {
            ForEach(songs.indices.filter { matches[$0] != nil }, id: \.self) { i in
                if let t = matches[i] {
                    HStack(spacing: 10) {
                        ArtworkView(url: t.artworkURL).frame(width: 36, height: 36)
                        VStack(alignment: .leading) {
                            Text(t.title).lineLimit(1)
                            Text("Spotify: \(songs[i].title) – \(songs[i].artist)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Azioni

    private func fetchLink() {
        error = nil
        let l = link.trimmingCharacters(in: .whitespaces)
        phase = .matching(done: 0, total: 0)
        Task {
            do {
                let result = try await SpotifyImporter.fetch(link: l)
                start(name: result.name, songs: result.songs)
            } catch {
                self.error = error.localizedDescription
                phase = .input
            }
        }
    }

    private func start(name: String, songs: [ImportedSong]) {
        error = nil
        self.name = name
        self.songs = songs
        phase = .matching(done: 0, total: songs.count)
        Task {
            let total = songs.count
            let result = await SpotifyImporter.match(songs) { done in
                phase = .matching(done: done, total: total)
            }
            matches = result
            phase = .review
        }
    }
}

/// Impostazioni: qualità, radio, spazio occupato.
struct SettingsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("downloadLowQuality") private var downloadLowQuality = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Risparmio dati in streaming", isOn: $player.streamLowQuality)
                    Toggle("Download a qualità ridotta", isOn: $downloadLowQuality)
                } header: {
                    Text("Qualità audio")
                } footer: {
                    Text("Di base Armonia usa la qualità più alta che YouTube Music offre (AAC, di solito 128 kbps). YouTube non ha audio lossless: per ascoltare in FLAC o ALAC importa i tuoi file con + → Importa file audio.")
                }

                Section {
                    Toggle("Radio automatica", isOn: $player.autoRadio)
                } footer: {
                    Text("Quando la coda sta per finire aggiunge brani simili.")
                }

                Section("Spazio sul telefono") {
                    LabeledContent("Brani scaricati", value: "\(library.downloads.count) · \(formatBytes(Storage.size(of: Storage.downloads)))")
                    LabeledContent("File importati", value: "\(library.locals.count) · \(formatBytes(Storage.size(of: Storage.locals)))")
                    Button("Elimina tutti i download", role: .destructive) { confirmDelete = true }
                        .disabled(library.downloads.isEmpty)
                }

                Section {
                    LabeledContent("Versione", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
            .confirmationDialog("Eliminare tutti i brani scaricati?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) { library.removeAllDownloads() }
            }
        }
    }
}
