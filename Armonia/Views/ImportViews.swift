import SwiftUI
import UniformTypeIdentifiers
import WebKit

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
    @State private var showExportify = false
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
            .sheet(isPresented: $showExportify) {
                ExportifySheet { fileName, text in
                    showExportify = false
                    importCSV(text: text, name: fileName)
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
                importCSV(text: text, name: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    // MARK: - Fasi

    @ViewBuilder
    private var inputForm: some View {
        Section {
            Button {
                error = nil
                showExportify = true
            } label: {
                Label("Accedi a Spotify e scegli la playlist", systemImage: "person.crop.circle.badge.checkmark")
            }
        } header: {
            Text("Consigliato · nessun limite di brani")
        } footer: {
            Text("Si apre Exportify: accedi con il tuo account Spotify, poi tocca \"Export\" accanto alla playlist (anche \"Brani che ti piacciono\" e quelle private). Armonia riceve l'elenco completo da sola.")
        }

        Section {
            TextField("https://open.spotify.com/playlist/…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Importa dal link") { fetchLink() }
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Veloce · solo playlist pubbliche")
        } footer: {
            Text("In Spotify: ··· sulla playlist → Condividi → Copia link. Senza accesso Spotify mostra solo i primi brani (circa 100): per playlist lunghe usa l'accesso qui sopra.")
        }

        Section {
            Button("Scegli file CSV…") { showCSVPicker = true }
        } header: {
            Text("Da file")
        } footer: {
            Text("Se hai già esportato una playlist in CSV (per esempio da exportify.app sul computer), salvala nell'app File e sceglila qui.")
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
                if total > 200 {
                    Text("Playlist lunga: ci vorrà qualche minuto. Tieni l'app aperta, lo schermo resta acceso da solo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var reviewForm: some View {
        let found = matches.compactMap { $0 }
        Section {
            TextField("Nome playlist", text: $name, axis: .vertical)
                .lineLimit(1...4)
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

    private func importCSV(text: String, name: String) {
        let parsed = SpotifyImporter.parseCSV(text)
        guard !parsed.isEmpty else {
            error = "Nel file non ho trovato le colonne \"Track Name\" e \"Artist Name(s)\"."
            return
        }
        start(name: name.replacingOccurrences(of: "_", with: " "), songs: parsed)
    }

    private func start(name: String, songs: [ImportedSong]) {
        error = nil
        self.name = name
        self.songs = songs
        phase = .matching(done: 0, total: songs.count)
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
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
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var cacheSize: Int64 = Storage.size(of: Storage.opusCache)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    qualityPicker("Streaming", selection: $player.streamQuality)
                } header: {
                    Text("Qualità in streaming")
                } footer: {
                    Text(player.streamQuality == .high
                         ? "Alta: Opus tra 130 e 160 kbps a seconda del brano, il formato migliore che YouTube offre senza Premium. I brani scaricati in AAC restano in AAC finché non li riscarichi. Ogni brano parte dopo 1–3 secondi (viene scaricato e preparato), il successivo è già pronto. Se un brano non è disponibile in Opus si usa l'AAC."
                         : "Normale è l'AAC a circa 128 kbps. Risparmio dati usa circa 48 kbps, utile con poca connessione.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostica alta qualità", systemImage: "stethoscope")
                    }
                }

                Section {
                    qualityPicker("Download", selection: $downloads.quality)
                    if downloads.upgradableCount > 0 {
                        Button {
                            downloads.upgradeDownloads()
                        } label: {
                            Label("Riscarica \(downloads.upgradableCount) brani in alta qualità", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } header: {
                    Text("Qualità dei download")
                } footer: {
                    Text("Vale per i brani che scarichi da ora in poi. YouTube non ha audio lossless: per FLAC o ALAC importa i tuoi file con + → Importa file audio.")
                }

                Section("Aspetto") {
                    NavigationLink {
                        IconPickerView()
                    } label: {
                        Label("Icona dell'app", systemImage: "app.badge")
                    }
                }

                Section {
                    Toggle("Radio automatica", isOn: $player.autoRadio)
                } footer: {
                    Text("Quando la coda sta per finire aggiunge brani simili.")
                }

                Section("Spazio sul telefono") {
                    LabeledContent("Brani scaricati", value: "\(library.downloads.count) · \(formatBytes(Storage.size(of: Storage.downloads)))")
                    LabeledContent("File importati", value: "\(library.locals.count) · \(formatBytes(Storage.size(of: Storage.locals)))")
                    LabeledContent("Cache alta qualità", value: formatBytes(cacheSize))
                    Button("Svuota cache alta qualità") {
                        Task {
                            await OpusCache.shared.clear()
                            cacheSize = Storage.size(of: Storage.opusCache)
                        }
                    }
                    .disabled(cacheSize == 0)
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

    private func qualityPicker(_ title: String, selection: Binding<AudioQuality>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AudioQuality.allCases) { q in
                VStack(alignment: .leading) {
                    Text(q.label)
                    Text(q.detail).font(.caption).foregroundStyle(.secondary)
                }
                .tag(q)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}


// MARK: - Exportify dentro l'app

/// Apre exportify.app in una finestra interna e intercetta il CSV scaricato.
struct ExportifySheet: View {
    let onCSV: (_ name: String, _ text: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ExportifyWebView(onCSV: onCSV, onMessage: { message = $0 }, onLoading: { loading = $0 })
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .padding(10)
                            .glassRect(10)
                            .padding()
                    }
                }
                .navigationTitle("Exportify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { if loading { ProgressView() } }
                }
        }
    }
}

struct ExportifyWebView: UIViewRepresentable {
    let onCSV: (String, String) -> Void
    let onMessage: (String?) -> Void
    let onLoading: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // resta collegato a Spotify tra un import e l'altro
        let web = WKWebView(frame: .zero, configuration: config)
        // User agent di Safari: alcuni accessi (es. "Continua con Google") rifiutano le finestre interne.
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: URL(string: "https://exportify.app/")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let parent: ExportifyWebView
        private var destinations: [ObjectIdentifier: URL] = [:]

        init(_ parent: ExportifyWebView) { self.parent = parent }

        // I CSV arrivano come download (link con attributo "download" o file non visualizzabile).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.shouldPerformDownload ? .download : .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            let mime = navigationResponse.response.mimeType ?? ""
            let isCSV = mime.contains("csv") || (navigationResponse.response.suggestedFilename ?? "").hasSuffix(".csv")
            return isCSV || !navigationResponse.canShowMIMEType ? .download : .allow
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        // Finestre "popup" (target=_blank): si aprono nella stessa vista.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoading(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoading(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoading(false)
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String) async -> URL? {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(suggestedFilename.isEmpty ? "playlist.csv" : suggestedFilename)
            destinations[ObjectIdentifier(download)] = url
            parent.onMessage("Ricevo la playlist…")
            return url
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            if url.pathExtension.lowercased() == "zip" {
                parent.onMessage("Hai scaricato un archivio ZIP: esporta le playlist una alla volta con \"Export\".")
                return
            }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                parent.onMessage("Non riesco a leggere il file scaricato.")
                return
            }
            parent.onMessage(nil)
            parent.onCSV(url.deletingPathExtension().lastPathComponent, text)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            parent.onMessage("Download non riuscito: \(error.localizedDescription)")
        }
    }
}
