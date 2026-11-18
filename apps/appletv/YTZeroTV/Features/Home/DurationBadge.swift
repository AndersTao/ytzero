import SwiftUI

/// The video's length in the thumbnail's lower right corner, as on YouTube.
struct DurationBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

/// "Channel · 1 hr. ago" under a card.
struct ChannelLine: View {
    let video: Video

    var body: some View {
        if let ago = video.publishedAgo {
            Text(verbatim: "\(video.channelTitle) · \(ago)")
        } else {
            Text(verbatim: video.channelTitle)
        }
    }
}
