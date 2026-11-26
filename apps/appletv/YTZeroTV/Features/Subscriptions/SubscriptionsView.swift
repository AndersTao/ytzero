import SwiftUI

/// The channels this profile follows, as the iPhone and iPad list them: a
/// round picture, the name and when the latest video came, the latest first.
/// Select opens the channel's videos; Menu goes back to the channels.
struct SubscriptionsView: View {
    /// Raised by the sidebar's Refresh.
    let refreshSignal: Int
    /// Refresh on the screen itself, before tvOS 27.
    let header: ScreenHeader?

    @Environment(AppSession.self) private var session
    @State private var channels: [APIModels.Channel] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var path: [APIModels.Channel] = []
    @FocusState private var focusedChannel: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 56, alignment: .top), count: 5)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    if let header {
                        HStack {
                            Spacer()
                            Button(action: header.refresh) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .focusSection()
                    }
                    LazyVGrid(columns: columns, spacing: 64) {
                        ForEach(channels) { channel in
                            NavigationLink(value: channel) {
                                ChannelTile(channel: channel, client: session.client)
                            }
                            .buttonStyle(.borderless)
                            .focused($focusedChannel, equals: channel.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .overlay {
                if !loaded {
                    ProgressView()
                } else if failed {
                    ContentUnavailableView("The channels could not be loaded.", systemImage: "wifi.exclamationmark")
                } else if channels.isEmpty {
                    ContentUnavailableView("No subscriptions", systemImage: "person.2")
                }
            }
            .defaultFocus($focusedChannel, channels.first?.id)
            .navigationDestination(for: APIModels.Channel.self) { channel in
                ChannelVideosView(channel: channel)
            }
        }
        .task { await load() }
        .onChange(of: refreshSignal) { Task { await load() } }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let loadedChannels = try await client.channels()
            // The latest video first, as the web's default; then by name.
            channels = loadedChannels.sorted {
                ($0.latestVideo ?? .distantPast, $1.title) > ($1.latestVideo ?? .distantPast, $0.title)
            }
            failed = false
        } catch APIError.unauthorized {
            session.signOut()
        } catch is CancellationError {
        } catch {
            failed = channels.isEmpty
        }
        loaded = true
    }
}

/// A round picture, the name, and "26.6M subscribers · 2 hr. ago".
private struct ChannelTile: View {
    let channel: APIModels.Channel
    let client: APIClient?

    var body: some View {
        VStack(spacing: 18) {
            ChannelPicture(source: channel.thumbnail, client: client)
                .frame(width: 200, height: 200)
            VStack(spacing: 6) {
                Text(verbatim: channel.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if !details.isEmpty {
                    Text(verbatim: details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var details: String {
        var parts: [String] = []
        if let count = channel.subscriberCount, !count.isEmpty {
            parts.append(String(localized: "\(count) subscribers"))
        }
        if let latest = channel.latestVideo {
            parts.append(Video.ago(latest))
        }
        return parts.joined(separator: " · ")
    }
}

/// A channel's round picture, through the server's image proxy.
private struct ChannelPicture: View {
    let source: String?
    let client: APIClient?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(.circle)
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source, let client else { return }
        if let cached = ThumbnailCache.shared.image(for: source) {
            image = cached
            return
        }
        guard let data = try? await client.imageData(for: source), let original = UIImage(data: data),
              let prepared = await original.byPreparingThumbnail(ofSize: CGSize(width: 400, height: 400 * original.size.height / max(original.size.width, 1)))
        else { return }
        ThumbnailCache.shared.store(prepared, for: source)
        image = prepared
    }
}

/// One channel's videos, newest first, watched or not, as its page on the
/// web shows them. Select plays full screen; a long press marks as watched.
struct ChannelVideosView: View {
    let channel: APIModels.Channel

    @Environment(AppSession.self) private var session
    @State private var videos: [Video] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var page = 0
    @State private var hasMore = true
    @State private var loadingMore = false
    @State private var playing: Video?
    @State private var notice: String?
    @FocusState private var focusedVideo: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4)
    private static let pageSize = 40

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text(verbatim: channel.title)
                    .font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 56) {
                    ForEach(videos) { video in
                        VideoCard(
                            video: video,
                            client: session.client,
                            focus: $focusedVideo,
                            play: { playing = video },
                            markWatched: { markWatched(video) }
                        )
                        .task { await appeared(video) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .overlay {
            if !loaded {
                ProgressView()
            } else if failed {
                ContentUnavailableView("The videos could not be loaded.", systemImage: "wifi.exclamationmark")
            } else if videos.isEmpty {
                ContentUnavailableView("No videos", systemImage: "play.rectangle")
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.headline)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 18)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 40)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if self.notice == notice { self.notice = nil }
                    }
            }
        }
        .defaultFocus($focusedVideo, videos.first?.id)
        .task { await loadFirstPage() }
        .fullScreenCover(item: $playing) { video in
            PlayerView(video: video) {} onClosed: { watched in
                // The card shows how far it got.
                if let index = videos.firstIndex(where: { $0.id == watched.id }) { videos[index] = watched }
            }
        }
    }

    private func loadFirstPage() async {
        guard let client = session.client else { return }
        do {
            let batch = try await client.channelVideos(channel.id, page: 0)
            videos = batch.filter(\.isPlayable)
            hasMore = batch.count == Self.pageSize
            page = 1
            failed = false
        } catch APIError.unauthorized {
            session.signOut()
        } catch is CancellationError {
        } catch {
            failed = videos.isEmpty
        }
        loaded = true
    }

    /// The next page, once the grid nears its end.
    private func appeared(_ video: Video) async {
        guard hasMore, !loadingMore, let client = session.client,
              let index = videos.firstIndex(of: video), index >= videos.count - 8 else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let batch = try? await client.channelVideos(channel.id, page: page) else { return }
        hasMore = batch.count == Self.pageSize
        page += 1
        let known = Set(videos.map(\.id))
        videos += batch.filter { $0.isPlayable && !known.contains($0.id) }
    }

    private func markWatched(_ video: Video) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.markWatched(video.id)
                notice = String(localized: "Marked as watched")
            } catch {
                notice = String(localized: "Something went wrong – try again")
            }
        }
    }
}
