import Foundation
import Combine
import UIKit

/// Scarica un flusso audio in un file, a blocchi (YouTube rallenta o blocca i download in un pezzo solo).
enum AudioFetch {
    static let chunkSize: Int64 = 4 * 1024 * 1024

    static func download(_ info: StreamInfo, to dest: URL,
                         isCancelled: @escaping () -> Bool = { false },
                         progress: @escaping (Double) -> Void = { _ in }) async throws {
        let temp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: temp)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        var closed = false
        defer { if !closed { try? handle.close() } }

        var offset: Int64 = 0
        let total = info.contentLength
        while true {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
            let end = offset + chunkSize - 1
            var req = URLRequest(url: info.url, timeoutInterval: 30)
            req.setValue("bytes=\(offset)-\(total.map { min(end, $0 - 1) } ?? end)", forHTTPHeaderField: "Range")
            req.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 416 { break }  // oltre la fine del file
            guard code == 200 || code == 206 else { throw InnertubeError.http(code) }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if let total, total > 0 { progress(min(Double(offset) / Double(total), 1)) }
            if code == 200 || data.isEmpty || Int64(data.count) < chunkSize { break }
            if let total, offset >= total { break }
        }
        try handle.close()
        closed = true
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
    }

    /// Scarica un brano Opus (WebM) e lo converte in CAF, riproducibile da iOS.
    static func downloadOpus(_ info: StreamInfo, to dest: URL,
                             isCancelled: @escaping () -> Bool = { false },
                             progress: @escaping (Double) -> Void = { _ in }) async throws {
        let webm = dest.deletingPathExtension().appendingPathExtension("webm")
        defer { try? FileManager.default.removeItem(at: webm) }
        try await download(info, to: webm, isCancelled: isCancelled, progress: progress)
        let tmp = dest.deletingPathExtension().appendingPathExtension("tmp.caf")
        try await Task.detached(priority: .userInitiated) {
            try OpusRemuxer.convert(webm: webm, to: tmp)
        }.value
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

/// Insieme di ID annullati, leggibile da qualsiasi thread.
final class CancelFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()

    func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    func remove(_ id: String) { lock.lock(); ids.remove(id); lock.unlock() }
    func removeAll() { lock.lock(); ids.removeAll(); lock.unlock() }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}

/// Scarica i brani uno alla volta per l'ascolto offline.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Avanzamento 0...1 dei brani in coda o in corso.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published var quality: AudioQuality = AudioQuality.stored("downloadQuality", legacyLowKey: "downloadLowQuality") {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "downloadQuality") }
    }

    weak var library: LibraryStore?

    private var pending: [Track] = []
    private var worker: Task<Void, Never>?
    private let cancelled = CancelFlags()

    var activeCount: Int { progress.count }

    func isQueued(_ t: Track) -> Bool { progress[t.id] != nil }

    func download(_ tracks: [Track]) {
        for t in tracks where !t.isLocal && progress[t.id] == nil && !(library?.isDownloaded(t) ?? false) {
            pending.append(t)
            cancelled.remove(t.id)
            progress[t.id] = 0
            failures[t.id] = nil
        }
        startWorker()
    }

    func cancel(_ t: Track) {
        cancelled.insert(t.id)
        pending.removeAll { $0.id == t.id }
        progress[t.id] = nil
    }

    func cancelAll() {
        for id in progress.keys { cancelled.insert(id) }
        pending.removeAll()
        worker?.cancel()
        worker = nil
        progress.removeAll()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            // Chiede a iOS qualche minuto extra se l'app va in background durante i download.
            let bg = UIApplication.shared.beginBackgroundTask(withName: "download")
            defer { UIApplication.shared.endBackgroundTask(bg) }
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let t = self.pending.removeFirst()
                do {
                    try await self.fetch(t)
                    self.library?.markDownloaded(t)
                } catch is CancellationError {
                    // annullato
                } catch {
                    self.failures[t.id] = error.localizedDescription
                }
                self.progress[t.id] = nil
            }
            self?.worker = nil
        }
    }

    private func fetch(_ t: Track) async throws {
        let id = t.id
        let flags = self.cancelled
        let cancelled: () -> Bool = { flags.contains(id) }
        let report: (Double) -> Void = { [weak self] p in
            Task { @MainActor in if self?.progress[id] != nil { self?.progress[id] = p } }
        }

        // Episodi dei podcast: file audio diretto.
        if let media = t.mediaURL, let url = URL(string: media) {
            var ext = url.pathExtension.lowercased()
            if !["mp3", "m4a", "aac", "mp4"].contains(ext) { ext = "mp3" }
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("Armonia/1.0 (iPhone; podcast player)", forHTTPHeaderField: "User-Agent")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(code) else { throw InnertubeError.http(code) }
            if flags.contains(id) { throw CancellationError() }
            let dest = Storage.downloadURL(for: id, ext: ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            Storage.removeDownloadFiles(for: id, except: ext)
            return
        }

        let info = try await Innertube.shared.stream(for: id, quality: quality, forDownload: true)
        guard !info.isHLS else { throw InnertubeError.notDownloadable }

        if info.isOpus {
            do {
                try await AudioFetch.downloadOpus(info, to: Storage.downloadURL(for: id, ext: "caf"),
                                                  isCancelled: cancelled, progress: report)
                Storage.removeDownloadFiles(for: id, except: "caf")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Se la conversione Opus non riesce, si ripiega sull'AAC.
            }
        }
        let aac = info.isOpus
            ? try await Innertube.shared.stream(for: id, quality: .normal, forDownload: true)
            : info
        try await AudioFetch.download(aac, to: Storage.downloadURL(for: id, ext: "m4a"),
                                      isCancelled: cancelled, progress: report)
        Storage.removeDownloadFiles(for: id, except: "m4a")
    }
}
