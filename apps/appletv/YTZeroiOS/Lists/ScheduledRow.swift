import SwiftUI

/// A scheduled video as the web's Scheduled page lists it: a small picture,
/// title and channel, when it is due, the times it can be moved to (the one
/// it has lit) and a cross that takes it off. On a phone the times go on a
/// line of their own under the rest.
struct ScheduledRow: View {
    let video: Video
    let client: APIClient?
    let play: () -> Void
    let move: (String) -> Void
    let remove: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 16) {
                summary
                if let due { dueText(due) }
                picker
                removeButton
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                summary
                HStack(alignment: .bottom, spacing: 8) {
                    picker
                    Spacer(minLength: 4)
                    removeButton
                }
            }
        }
    }

    private var due: String? {
        video.showFrom.map { ScheduleGroups.when($0) }
    }

    private var summary: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(source: video.thumbnail, client: client)
                    .overlay(alignment: .bottom) {
                        if let progress = video.progress {
                            ProgressBar(value: progress)
                                .scaleEffect(0.5, anchor: .bottom)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let length = video.durationText {
                            DurationBadge(text: length)
                                .scaleEffect(0.85, anchor: .bottomTrailing)
                                .padding(4)
                        }
                    }
                    .frame(width: horizontalSizeClass == .regular ? 160 : 128)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: video.channelTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if horizontalSizeClass != .regular, let due {
                        dueText(due)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(video.title), \(video.channelTitle)"))
        .accessibilityValue(Text(verbatim: due ?? ""))
    }

    private func dueText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Today (morning, evening), Tomorrow (morning, evening), Weekend: a
    /// caption over each pair, the time the video has lit up.
    private var picker: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(ScheduleGroups.choices, id: \.title) { group in
                VStack(spacing: 4) {
                    // The buttons say it themselves to VoiceOver.
                    Text(verbatim: group.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                    HStack(spacing: 2) {
                        ForEach(group.buckets, id: \.bucket) { choice in
                            let chosen = video.bucket == choice.bucket
                            Button {
                                move(choice.bucket)
                            } label: {
                                Image(systemName: choice.systemImage)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(width: group.buckets.count == 1 ? 60 : 30, height: 30)
                                    .foregroundStyle(chosen ? Color.blue : .primary)
                                    .background(chosen ? Color.blue.opacity(0.25) : .clear, in: .rect(cornerRadius: 7))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: choice.name))
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                    .padding(2)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 9))
                }
            }
        }
    }

    private var removeButton: some View {
        Button(action: remove) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove from Scheduled"))
    }
}
