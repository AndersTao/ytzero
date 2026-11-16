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
        guard let data = try? await client.imageData(for: source), let decoded = UIImage(data: data) else { return }
        ThumbnailCache.shared.store(decoded, for: source)
        image = decoded
    }
}
