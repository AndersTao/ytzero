import CryptoKit
import SwiftUI

/// Decoded thumbnails, so scrolling back does not fetch them again.
nonisolated final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    // NSCache is safe to use from several threads.
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // By size, not count: a few hundred decoded thumbnails are hundreds
        // of megabytes, more than an older iPad can spare.
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
    }
}

/// Pictures kept on this device beside videos kept for offline viewing, so
/// their cards still have them without a connection. Keyed by the address
/// the server gave the picture.
nonisolated enum OfflineImages {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Offline/Images", directoryHint: .isDirectory)
    }

    static func file(for source: String) -> URL {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: String(digest.prefix(32)))
    }

    static func data(for source: String) -> Data? {
        try? Data(contentsOf: file(for: source))
    }

    static func store(_ data: Data, for source: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: source), options: .atomic)
    }

    static func remove(_ source: String) {
        try? FileManager.default.removeItem(at: file(for: source))
    }
}
