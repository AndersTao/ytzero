import SwiftUI

/// Downloads in the side menu: the videos kept on this device, newest first,
/// each with how far it has come — the server fetching it, the transfer here,
/// or ready, with its size. Tap a ready one to play it, with or without a
/// connection; swipe to delete. Works with no server in reach.
struct DownloadsScreen: View {
    @Environment(AppSession.self) private var session
    @State private var player = PlayerPresenter()
    private var store: OfflineStore { .shared }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.entries) { entry in
                    DownloadRow(entry: entry, client: session.client) {
                        play(entry)
                    } retry: {
                        guard let client = session.client else { return }
                        store.retry(entry.id, client: client)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.remove(entry.id)
                        }
                    }
                    .contextMenu {
                        Button("Delete download", systemImage: "trash", role: .destructive) {
                            store.remove(entry.id)
                        }
                    }
                }
                if store.totalBytes > 0 {
                    Section {
                        LabeledContent("On this device", value: store.totalBytes.formatted(.byteCount(style: .file)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Touch and hold a video and choose Download to watch it without a connection."))
                }
            }
            .navigationTitle(Text("Downloads"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MenuButton() }
            }
        }
        .task {
            guard let client = session.client else { return }
            await store.resume(client: client)
        }
    }

    private func play(_ entry: OfflineStore.Entry) {
        guard entry.state == .ready, let client = session.client else { return }
        player.present(video: entry.video, client: client) {} onClose: { _ in }
    }
}

private struct DownloadRow: View {
    let entry: OfflineStore.Entry
    let client: APIClient?
    let play: () -> Void
    let retry: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(source: entry.video.thumbnail, client: client)
                    .overlay(alignment: .bottom) {
                        if entry.state == .ready, let progress = watched {
                            ProgressBar(value: progress)
                                .scaleEffect(0.5, anchor: .bottom)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let length = entry.video.durationText {
                            DurationBadge(text: length)
                                .scaleEffect(0.85, anchor: .bottomTrailing)
                                .padding(4)
                        }
                    }
                    .frame(width: 128)
                    .clipShape(.rect(cornerRadius: 8))
                    .opacity(entry.state == .ready ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: entry.video.channelTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(entry.state != .ready && entry.state != .failed)
        .accessibilityIdentifier("download-\(entry.id)")
    }

    private var percent: String {
        entry.progress.formatted(.percent.precision(.fractionLength(0)))
    }

    private var watched: Double? {
        guard let position = entry.position ?? entry.video.watchPosition,
              let duration = entry.duration ?? entry.video.watchDuration, duration > 0, position > 0 else { return nil }
        return min(1, position / duration)
    }

    @ViewBuilder
    private var status: some View {
        switch entry.state {
        case .requesting:
            step(Text("Asking the server…"), progress: nil)
        case .serverFetching:
            step(Text("The server is fetching it… \(percent)"), progress: entry.progress)
        case .transferring:
            step(Text("Coming to this device… \(percent)"), progress: entry.progress)
        case .ready:
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                Text(verbatim: (entry.bytes ?? 0).formatted(.byteCount(style: .file)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: entry.error ?? String(localized: "The download failed."))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
        }
    }

    private func step(_ text: Text, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            text
                .font(.caption)
                .foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView(value: 0).opacity(0.3)
            }
        }
    }
}

/// "Download" in a video's menu, or "Delete download" once it is kept here.
struct DownloadMenuItem: View {
    let video: Video
    let client: APIClient?

    var body: some View {
        if OfflineStore.shared.entry(for: video.id) != nil {
            Button("Delete download", systemImage: "trash", role: .destructive) {
                OfflineStore.shared.remove(video.id)
            }
        } else if !video.isShort, video.liveStatus != "live", video.liveStatus != "upcoming", let client {
            Button("Download", systemImage: "arrow.down.circle") {
                OfflineStore.shared.download(video, client: client)
            }
        }
    }
}
