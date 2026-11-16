import SwiftUI

/// Thumbnail, channel and title. Select plays; a long press offers
/// "Mark as watched" and "Reject".
struct VideoCard: View {
    let video: Video
    let client: APIClient?
    let focus: FocusState<String?>.Binding
    let play: () -> Void
    let markWatched: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: play) {
                Thumbnail(source: video.thumbnail, client: client)
                    .overlay(alignment: .bottom) {
                        if let progress = video.progress {
                            ProgressBar(value: progress)
                        }
                    }
            }
            .buttonStyle(.card)
            .focused(focus, equals: video.id)
            .contextMenu {
                Button("Mark as watched", systemImage: "eye", action: markWatched)
                Button("Reject", systemImage: "xmark.circle", role: .destructive, action: reject)
            }
            .accessibilityLabel(Text("\(video.title), \(video.channelTitle)"))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(video.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
            }
            .accessibilityHidden(true)
        }
    }
}
