import SwiftUI

/// A scheduled video as the web's Scheduled page lists it, for the remote:
/// the picture, title, channel and when it is due on one button that plays
/// it, then the times it can be moved to (the one it has lit) and a cross
/// that takes it off. Right moves along them; the row is a focus section of
/// its own, so Down goes to the next video.
struct ScheduledRow: View {
    let video: Video
    let client: APIClient?
    let focus: FocusState<String?>.Binding
    let play: () -> Void
    let markWatched: () -> Void
    let move: (String) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 32) {
            Button(action: play) {
                HStack(spacing: 28) {
                    Thumbnail(source: video.thumbnail, client: client)
                        .overlay(alignment: .bottom) {
                            if let progress = video.progress {
                                ProgressBar(value: progress)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if let length = video.durationText {
                                DurationBadge(text: length)
                                    .padding(8)
                            }
                        }
                        .frame(width: 260)
                        .clipShape(.rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(video.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        Text(verbatim: video.channelTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let due = video.showFrom.map({ ScheduleGroups.when($0) }) {
                            Text(verbatim: due)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .buttonStyle(.card)
            .focused(focus, equals: video.id)
            .contextMenu {
                Button("Mark as watched", systemImage: "eye", action: markWatched)
            }
            .accessibilityLabel(Text("\(video.title), \(video.channelTitle)"))

            picker
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text("Remove from Scheduled"))
        }
        .focusSection()
    }

    /// Today (morning, evening), Tomorrow (morning, evening), Weekend: a
    /// caption over each, the time the video has lit in blue.
    private var picker: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ForEach(ScheduleGroups.choices, id: \.title) { group in
                VStack(spacing: 10) {
                    Text(verbatim: group.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                    HStack(spacing: 12) {
                        ForEach(group.buckets, id: \.bucket) { choice in
                            let chosen = video.bucket == choice.bucket
                            Button {
                                move(choice.bucket)
                            } label: {
                                Image(systemName: choice.systemImage)
                                    .foregroundStyle(chosen ? Color.blue : .primary)
                            }
                            .tint(chosen ? .blue : nil)
                            .accessibilityLabel(Text(verbatim: choice.name))
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }
}
