import SwiftUI

/// Thumbnail, channel and title. Select plays; a long press offers
/// "Mark as watched", and "Reject" where the list has new videos to reject.
struct VideoCard: View {
    let video: Video
    let client: APIClient?
    let focus: FocusState<String?>.Binding
    let play: () -> Void
    let markWatched: () -> Void
    var reject: (() -> Void)? = nil
    /// Takes it off Scheduled, where that list offers it.
    var unschedule: (() -> Void)? = nil
    /// A Short: upright, its words on the picture (see ShortFace).
    var tall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: play) {
                if tall {
                    ShortFace(video: video, client: client, large: true)
                } else {
                    picture
                }
            }
            .buttonStyle(.card)
            .focused(focus, equals: video.id)
            .contextMenu {
                Button("Mark as watched", systemImage: "eye", action: markWatched)
                if let unschedule {
                    Button("Remove from Scheduled", systemImage: "calendar.badge.minus", action: unschedule)
                }
                if let reject {
                    Button("Reject", systemImage: "xmark.circle", role: .destructive, action: reject)
                }
            }
            .accessibilityLabel(Text("\(video.title), \(video.channelTitle)"))

            // A Short's card carries its words on the picture.
            if !tall {
                VStack(alignment: .leading, spacing: 4) {
                    ChannelLine(video: video)
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

    private var picture: some View {
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
            .overlay(alignment: .bottomTrailing) {
                if let length = video.durationText {
                    // Above the progress bar when there is one.
                    DurationBadge(text: length)
                        .padding(.horizontal, 12)
                        .padding(.bottom, video.progress == nil ? 12 : 30)
                }
            }
    }
}
