import SwiftUI

/// A Short as the web client's Shorts cards show it: the upright picture
/// filling the card, and over its darkened foot the title, the channel with
/// its picture, and views and age. Shared by the iPhone, iPad and Apple TV
/// cards; each sizes it and makes it a button.
struct ShortFace: View {
    let video: Video
    let client: APIClient?
    /// The Apple TV's larger type and spacing.
    var large = false

    var body: some View {
        Thumbnail(source: video.thumbnail, client: client, aspectRatio: 9 / 16)
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.85), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .bottom) {
                if let progress = video.progress {
                    ProgressBar(value: progress)
                        .scaleEffect(large ? 1 : 0.6, anchor: .bottom)
                }
            }
            .clipShape(.rect(cornerRadius: large ? 20 : 14))
            .environment(\.colorScheme, .dark)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 6) {
            Text(video.title)
                .font(large ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: large ? 12 : 6) {
                if let picture = video.channelThumbnail {
                    Thumbnail(source: picture, client: client, aspectRatio: 1)
                        .frame(width: large ? 40 : 22, height: large ? 40 : 22)
                        .clipShape(.circle)
                }
                Text(verbatim: video.channelTitle)
                    .lineLimit(1)
            }
            .font(large ? .caption : .footnote)
            if let meta {
                Text(verbatim: meta)
                    .font(large ? .caption2 : .caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(large ? 2 : 1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .padding(large ? 20 : 10)
        .padding(.bottom, video.progress == nil ? 0 : (large ? 8 : 4))
    }

    /// "213.4K views · 21 hr. ago", leaving out what is not known.
    private var meta: String? {
        let views = video.views.map { count in
            String(localized: "\(count.formatted(.number.notation(.compactName))) views")
        }
        let parts = [views, video.publishedAgo].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
