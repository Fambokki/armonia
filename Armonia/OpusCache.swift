import Foundation

/// Cache dei brani in alta qualità (Opus convertito in CAF) ascoltati in streaming.
/// Evita di riscaricarli e permette di preparare in anticipo il brano successivo.
actor OpusCache {
    static let shared = OpusCache()
    private let maxFiles = 80

    private var inFlight: [String: Task<URL, Error>] = [:]
    private var labels: [String: String] = [:]

    nonisolated static func url(for id: String) -> URL {
        Storage.opusCache.appendingPathComponent(id + ".caf")
    }

    nonisolated static func cachedFile(for id: String) -> URL? {
        let u = url(for: id)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        // "tocca" il file, così la pulizia elimina per primi quelli non ascoltati da più tempo
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return u
    }

    nonisolated static func label(for id: String) -> String {
        UserDefaults.standard.string(forKey: "opusLabel-" + id) ?? "Opus"
    }

    func file(for id: String, info: StreamInfo) async throws -> URL {
        if let u = OpusCache.cachedFile(for: id) { return u }
        if let running = inFlight[id] { return try await running.value }
        let dest = OpusCache.url(for: id)
        let task = Task<URL, Error> {
            try await AudioFetch.downloadOpus(info, to: dest)
            UserDefaults.standard.set(info.label, forKey: "opusLabel-" + id)
            return dest
        }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        let u = try await task.value
        cleanup()
        return u
    }

    private func cleanup() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Storage.opusCache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cafs = files.filter { $0.pathExtension == "caf" }
        guard cafs.count > maxFiles else { return }
        let sorted = cafs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for f in sorted.prefix(cafs.count - maxFiles) { try? fm.removeItem(at: f) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: Storage.opusCache)
    }
}
