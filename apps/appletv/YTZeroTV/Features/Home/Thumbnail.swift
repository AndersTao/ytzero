import SwiftUI

/// A video thumbnail loaded through the server's image proxy, which needs the
/// session's bearer token, so `AsyncImage` cannot fetch it.
struct Thumbnail: View {
    let source: String?
    let client: APIClient?

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: source) { await load() }
    }

    private func load() async {
        guard let source, let client else { return }
        if let cached = ThumbnailCache.shared.image(for: source) {
            image = cached
            return
        }
        guard let data = try? await client.imageData(for: source), let original = UIImage(data: data) else { return }
        // Decoded once, in the background and at the size a card shows. A
        // JPEG handed straight to SwiftUI is decoded on the main thread the
        // first time it is drawn, at full size, which is what made scrolling
        // stutter on an older iPad.
        let width = min(original.size.width, Self.maxPixelWidth)
        let size = CGSize(width: width, height: (original.size.height * width / max(original.size.width, 1)).rounded())
        guard let prepared = await original.byPreparingThumbnail(ofSize: size) else { return }
        ThumbnailCache.shared.store(prepared, for: source)
        image = prepared
    }

    /// Wide enough for the largest card on any screen this runs on.
    private static let maxPixelWidth: CGFloat = 800
}
