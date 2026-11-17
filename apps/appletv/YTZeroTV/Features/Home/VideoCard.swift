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
                    .overlay(alignment: .topLeading) {
                        if let badge = video.liveBadge {
                            LiveBadge(kind: badge)
                                .padding(12)
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

/// "LIVE" on a stream that is on now, "Livestream" on a recording of one, so
/// they can be told from ordinary uploads at a glance.
struct LiveBadge: View {
    let kind: Video.LiveBadge

    var body: some View {
        Text(kind == .live ? "LIVE" : "Livestream")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(kind == .live ? Color.red : Color.black.opacity(0.75), in: .rect(cornerRadius: 8))
    }
}
