import SwiftUI
import AVFoundation

/// Verifica passo per passo la catena dell'alta qualità (Opus) su un brano reale.
struct DiagnosticsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    private struct Step: Identifiable {
        let id = UUID()
        var ok: Bool?
        var title: String
        var detail: String
    }

    @State private var steps: [Step] = []
    @State private var running = false
    @State private var trackName = ""

    var body: some View {
        List {
            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Label(running ? "Verifica in corso…" : "Avvia verifica", systemImage: "stethoscope")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running)
            } footer: {
                Text("Usa il brano in riproduzione (o l'ultimo ascoltato) e prova ogni passaggio: formati offerti da YouTube, download Opus, conversione e riproduzione. Se qualcosa non va, manda uno screenshot di questa pagina.")
            }

            if !trackName.isEmpty {
                Section("Brano di prova") { Text(trackName) }
            }

            if !steps.isEmpty {
                Section("Risultati") {
                    ForEach(steps) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.ok == nil ? "info.circle" : (s.ok! ? "checkmark.circle.fill" : "xmark.octagon.fill"))
                                .foregroundStyle(s.ok == nil ? Color.secondary : (s.ok! ? Color.green : Color.red))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.title).font(.subheadline.weight(.semibold))
                                Text(s.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section {
                    ShareLink(item: report) { Label("Condividi il risultato", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Diagnostica audio")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var report: String {
        (["Armonia – diagnostica alta qualità", "Brano: \(trackName)"] +
         steps.map { "[\($0.ok == nil ? "i" : ($0.ok! ? "OK" : "ERRORE"))] \($0.title): \($0.detail)" })
            .joined(separator: "\n")
    }

    private func add(_ ok: Bool?, _ title: String, _ detail: String) {
        steps.append(Step(ok: ok, title: title, detail: detail))
    }

    private func run() async {
        running = true
        steps = []
        defer { running = false }

        var track = player.current.flatMap { ($0.isLocal || $0.isPodcast) ? nil : $0 }
            ?? library.recents.first { !$0.isLocal && !$0.isPodcast }
        if track == nil { track = try? await Innertube.shared.search("Queen Bohemian Rhapsody").first }
        guard let t = track else {
            add(false, "Brano di prova", "Nessun brano disponibile: ascoltane uno e riprova.")
            return
        }
        trackName = "\(t.title) – \(t.artist) [\(t.id)]"

        // 1. Formati
        let lines = await Innertube.shared.formatsReport(for: t.id)
        add(nil, "Formati offerti da YouTube", lines.joined(separator: "\n"))

        // 1b. Client TV con firma cifrata (riserva per i video che visionOS non riceve)
        let tv = await Innertube.shared.signatureReport(for: t.id)
        add(tv.ok, "Riserva client TV (firma decifrata)", tv.text)

        // 2. Flusso in alta qualità
        let info: StreamInfo
        do {
            info = try await Innertube.shared.stream(for: t.id, quality: .high)
        } catch {
            add(false, "Richiesta alta qualità", error.localizedDescription)
            return
        }
        add(info.isOpus, "Richiesta alta qualità",
            "\(info.label) da \(info.client)\(info.note.map { " · " + $0 } ?? "")")
        guard info.isOpus else { return }

        // 3. Download
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let webm = dir.appendingPathComponent("test.webm")
        let start = Date()
        do {
            try await AudioFetch.download(info, to: webm)
            let size = (try? FileManager.default.attributesOfItem(atPath: webm.path)[.size] as? Int64) ?? 0
            add(true, "Download Opus", "\(formatBytes(size)) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        } catch {
            add(false, "Download Opus", error.localizedDescription)
            return
        }

        // 4. Lettura del WebM
        do {
            let data = try Data(contentsOf: webm)
            let p = try OpusRemuxer.parse(data)
            let frames = Set(p.packets.map { OpusRemuxer.samples(inPacket: data, $0) })
            let preskip = p.codecPrivate.map { $0.count >= 12 ? Int($0[$0.startIndex + 10]) | Int($0[$0.startIndex + 11]) << 8 : -1 } ?? -1
            add(true, "Lettura WebM", "\(p.packets.count) pacchetti · \(p.channels) canali · \(Int(p.sampleRate)) Hz · campioni/pacchetto \(frames.sorted()) · pre-skip \(preskip)")
        } catch {
            add(false, "Lettura WebM", error.localizedDescription)
            return
        }

        // 5. Conversione in CAF
        let caf = dir.appendingPathComponent("test.caf")
        do {
            try OpusRemuxer.convert(webm: webm, to: caf)
            let size = (try? FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int64) ?? 0
            add(true, "Conversione in CAF", formatBytes(size))
        } catch {
            add(false, "Conversione in CAF", error.localizedDescription)
            return
        }

        // 6. Lettura con AVAudioFile
        do {
            let f = try AVAudioFile(forReading: caf)
            let secs = Double(f.length) / f.fileFormat.sampleRate
            add(true, "Apertura file convertito", "\(f.fileFormat.settings[AVFormatIDKey].map { "\($0)" } ?? "?") · \(Int(f.fileFormat.sampleRate)) Hz · \(f.fileFormat.channelCount) canali · \(formatTime(secs))")
        } catch {
            add(false, "Apertura file convertito", error.localizedDescription)
        }

        // 7. Riproducibilità con AVPlayer
        let item = AVPlayerItem(url: caf)
        let testPlayer = AVPlayer(playerItem: item)
        testPlayer.volume = 0
        var waited = 0.0
        while item.status == .unknown && waited < 8 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
        }
        switch item.status {
        case .readyToPlay:
            add(true, "Riproduzione", "Pronto · durata \(formatTime(item.duration.seconds))")
        case .failed:
            add(false, "Riproduzione", item.error?.localizedDescription ?? "rifiutato")
        default:
            add(false, "Riproduzione", "nessuna risposta in 8 s")
        }
        testPlayer.replaceCurrentItem(with: nil)
    }
}
