import SwiftUI
import UIKit

/// Copertine: scaricate una volta, ridimensionate e decodificate fuori dal thread principale,
/// poi tenute in memoria. AsyncImage non ha cache propria e decodifica ogni volta: nelle liste
/// lunghe era una delle cause degli scatti.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 80 * 1024 * 1024
    }

    func cached(_ url: URL, size: Int) -> UIImage? {
        memory.object(forKey: key(url, size))
    }

    func image(for url: URL, size: Int) async -> UIImage? {
        let k = key(url, size)
        if let img = memory.object(forKey: k) { return img }

        lock.lock()
        if let running = inFlight[k as String] {
            lock.unlock()
            return await running.value
        }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            guard let data, let img = UIImage(data: data) else { return nil }
            // Ridimensiona alla dimensione d'uso e decodifica subito (niente lavoro durante lo scorrimento).
            let side = CGFloat(size)
            let target = img.size.width > side || img.size.height > side
                ? CGSize(width: side, height: side * img.size.height / max(img.size.width, 1))
                : img.size
            return await img.byPreparingThumbnail(ofSize: target) ?? img.preparingForDisplay() ?? img
        }
        inFlight[k as String] = task
        lock.unlock()

        let result = await task.value
        lock.lock()
        inFlight[k as String] = nil
        lock.unlock()
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            memory.setObject(result, forKey: k, cost: cost)
        }
        return result
    }

    private func key(_ url: URL, _ size: Int) -> NSString {
        "\(size)|\(url.absoluteString)" as NSString
    }
}
