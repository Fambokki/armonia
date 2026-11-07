import Foundation
import Combine
import UIKit

/// Scarica i brani uno alla volta, a blocchi (YouTube rallenta o blocca i download in un pezzo solo).
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Avanzamento 0...1 dei brani in coda o in corso.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failures: [String: String] = [:]

    weak var library: LibraryStore?

    private var pending: [Track] = []
    private var worker: Task<Void, Never>?
    private let chunkSize: Int64 = 4 * 1024 * 1024

    var activeCount: Int { progress.count }

    func isQueued(_ t: Track) -> Bool { progress[t.id] != nil }

    func download(_ tracks: [Track]) {
        for t in tracks where !t.isLocal && progress[t.id] == nil && !(library?.isDownloaded(t) ?? false) {
            pending.append(t)
            progress[t.id] = 0
            failures[t.id] = nil
        }
        startWorker()
    }

    func cancel(_ t: Track) {
        pending.removeAll { $0.id == t.id }
        progress[t.id] = nil
    }

    func cancelAll() {
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
        let lowQuality = UserDefaults.standard.bool(forKey: "downloadLowQuality")
        let info = try await Innertube.shared.stream(for: t.id, lowQuality: lowQuality, forDownload: true)
        guard !info.isHLS else { throw InnertubeError.notDownloadable }

        let dest = Storage.downloadURL(for: t.id)
        let temp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: temp)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }

        var offset: Int64 = 0
        let total = info.contentLength
        while true {
            try Task.checkCancellation()
            guard progress[t.id] != nil else { throw CancellationError() }
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
            if let total, total > 0 { progress[t.id] = min(Double(offset) / Double(total), 1) }
            if code == 200 || data.isEmpty || Int64(data.count) < chunkSize { break }
            if let total, offset >= total { break }
        }
        try handle.close()
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
    }
}
