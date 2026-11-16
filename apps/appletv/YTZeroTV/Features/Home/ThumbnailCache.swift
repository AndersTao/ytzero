import SwiftUI

/// Decoded thumbnails, so scrolling back does not fetch them again.
nonisolated final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    // NSCache is safe to use from several threads.
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
