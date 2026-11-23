import SwiftUI

/// Thumbnail, channel and title. Tap plays.
struct VideoCard: View {
    let video: Video
    let client: APIClient?
    /// The narrower card on the Continue watching shelf.
    let compact: Bool
    /// A Short: upright, its words on the picture (see ShortFace).
    var tall = false
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            if tall {
                ShortFace(video: video, client: client)
                    .contentShape(.rect)
            } else {
                card
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(video.title), \(video.channelTitle)"))
        .accessibilityValue(watchedText)
    }

    private var card: some View {
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
                .overlay(alignment: .topTrailing) { OfflineBadge(id: video.id) }
                .overlay(alignment: .bottomTrailing) {
                    if let length = video.durationText {
                        // Above the progress bar when there is one.
                        DurationBadge(text: length)
                            .padding(.horizontal, 8)
                            .padding(.bottom, video.progress == nil ? 8 : 18)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(2, reservesSpace: compact)
                    .multilineTextAlignment(.leading)
                ChannelLine(video: video)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }

    /// How far it was watched, for VoiceOver; the bar itself is hidden from it.
    private var watchedText: Text {
        guard video.progress != nil, let position = video.watchPosition, let duration = video.watchDuration else { return Text(verbatim: "") }
        return Text("Watched \(PlaybackTime.text(position)) of \(PlaybackTime.text(duration))")
    }
}

/// On a card whose video is kept on this device: a filled arrow when it is
/// all here, a ring of how far it has come while it is on its way.
struct OfflineBadge: View {
    let id: String

    var body: some View {
        if let entry = OfflineStore.shared.entry(for: id), entry.state != .failed {
            Group {
                if entry.state == .ready {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                } else {
                    ProgressView(value: entry.state == .transferring ? entry.progress : entry.progress * 0.5)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                        .padding(3)
                        .background(.black.opacity(0.6), in: .circle)
                }
            }
            .padding(8)
            .accessibilityLabel(Text(entry.state == .ready ? "Downloaded" : "Downloading"))
        }
    }
}
