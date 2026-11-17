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
