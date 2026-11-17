import SwiftUI

/// Thumbnail, channel and title. Tap plays.
struct VideoCard: View {
    let video: Video
    let client: APIClient?
    /// The narrower card on the Continue watching shelf.
    let compact: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(source: video.thumbnail, client: client)
                    .overlay(alignment: .bottom) {
                        if let progress = video.progress {
                            ProgressBar(value: progress)
                                .scaleEffect(0.6, anchor: .bottom)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let badge = video.liveBadge {
                            LiveBadge(kind: badge)
                                .padding(8)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .lineLimit(2, reservesSpace: compact)
                        .multilineTextAlignment(.leading)
                    Text(video.channelTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(video.title), \(video.channelTitle)"))
    }
}
