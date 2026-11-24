import SwiftUI

/// Downloads in the side menu: the videos kept on this device, newest first,
/// each with how far it has come — the server fetching it, the transfer here,
/// or ready, with its size. Tap a ready one to play it, with or without a
/// connection; swipe left to delete, right to lock it against being deleted
/// by the settings (the gear: quality, delete once watched, days kept).
/// Works with no server in reach.
struct DownloadsScreen: View {
    @Environment(AppSession.self) private var session
    @State private var player = PlayerPresenter()
    @State private var showingSettings = false
    @State private var confirmingDeleteAll = false
    @AppStorage(OfflineSettings.keepDaysKey) private var keepDays = 0
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
                    } delete: {
                        store.remove(entry.id)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.remove(entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        // Its own colour: the app's tint is white, which made
                        // the button a white disc with a white bin on it.
                        .tint(.red)
                        .accessibilityLabel(Text("Delete"))
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            store.togglePin(entry.id)
                        } label: {
                            Image(systemName: entry.pinned ? "lock.open" : "lock")
                        }
                        .tint(.orange)
                        .accessibilityLabel(entry.pinned ? Text("Unlock") : Text("Lock"))
                    }
                    .contextMenu {
                        Button(entry.pinned ? "Unlock" : "Lock", systemImage: entry.pinned ? "lock.open" : "lock") {
                            store.togglePin(entry.id)
                        }
                        Button("Delete download", systemImage: "trash", role: .destructive) {
                            store.remove(entry.id)
                        }
                    }
                }
                if !store.entries.isEmpty {
                    Section {
                        if store.totalBytes > 0 {
                            LabeledContent("On this device", value: store.totalBytes.formatted(.byteCount(style: .file)))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Delete all downloads", systemImage: "trash", role: .destructive) {
                            confirmingDeleteAll = true
                        }
                        .accessibilityIdentifier("delete-all")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Download settings", systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("download-settings")
                }
            }
            .confirmationDialog(Text("Delete all downloads?"), isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.removeAll(keepingPinned: false) }
                if store.entries.contains(where: \.pinned) {
                    Button("Delete all but the locked") { store.removeAll(keepingPinned: true) }
                }
            } message: {
                Text("They can be downloaded again while there is a connection.")
            }
            .sheet(isPresented: $showingSettings) { OfflineSettingsView() }
        }
        .task {
            guard store.profile != 0, let client = session.client else { return }
            await store.resume(client: client)
        }
        // Fewer days kept: what is now too old goes at once.
        .onChange(of: keepDays) { store.expire() }
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
    let delete: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        HStack(spacing: 16) {
            summary
            // On the iPad's wider rows a button of its own, as well as the swipe.
            if horizontalSizeClass == .regular {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Delete download"))
                .accessibilityIdentifier("delete-\(entry.id)")
            }
        }
    }

    private var summary: some View {
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
                Text(verbatim: [(entry.bytes ?? 0).formatted(.byteCount(style: .file)), entry.height.map { "\($0)p" }]
                    .compactMap { $0 }.joined(separator: " · "))
                if entry.pinned {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Locked"))
                }
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
        } else if OfflineStore.shared.profile != 0, !video.isShort, video.liveStatus != "live", video.liveStatus != "upcoming", let client {
            Button("Download", systemImage: "arrow.down.circle") {
                OfflineStore.shared.download(video, client: client)
            }
        }
    }
}

/// How copies are made and kept on this device: the quality asked of the
/// server, deleting once watched, and how many days a copy stays. Locked
/// copies stay whatever these say.
struct OfflineSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OfflineSettings.qualityKey) private var quality = 1080
    @AppStorage(OfflineSettings.deleteWhenWatchedKey) private var deleteWhenWatched = false
    @AppStorage(OfflineSettings.keepDaysKey) private var keepDays = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $quality) {
                        ForEach(OfflineSettings.qualities, id: \.self) { height in
                            Text(verbatim: "\(height)p").tag(height)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("download-quality")
                } header: {
                    Text("Quality")
                } footer: {
                    Text("For new downloads. Lower takes less space: roughly a third at 720p, a sixth at 480p.")
                }
                Section {
                    Toggle("Delete when watched", isOn: $deleteWhenWatched)
                        .accessibilityIdentifier("delete-when-watched")
                    Picker("Keep on device", selection: $keepDays) {
                        ForEach(OfflineSettings.keepChoices, id: \.self) { days in
                            keepText(days).tag(days)
                        }
                    }
                    .accessibilityIdentifier("keep-days")
                } footer: {
                    Text("Locked downloads stay until you delete them. Swipe right on a download to lock it.")
                }
            }
            .navigationTitle(Text("Download settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func keepText(_ days: Int) -> Text {
        switch days {
        case 0: Text("Until deleted")
        case 1: Text("1 day")
        default: Text("\(days) days")
        }
    }
}
