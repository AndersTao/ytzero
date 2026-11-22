import SwiftUI

/// The channels this profile follows, as on the web's Subscriptions page:
/// picture, name, subscribers and when the latest video came. Search by name,
/// sort four ways; a channel opens its videos.
struct SubscriptionsView: View {
    @Environment(AppSession.self) private var session
    @State private var channels: [APIModels.Channel] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var query = ""
    @AppStorage("subscriptionsSort") private var sort: Sort = .latestVideo

    enum Sort: String, CaseIterable, Identifiable {
        case latestVideo, name, subscribedRecent, subscribers
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .latestVideo: "Latest video"
            case .name: "Name"
            case .subscribedRecent: "Recently subscribed"
            case .subscribers: "Most subscribers"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(shown) { channel in
                NavigationLink(value: channel) {
                    ChannelRow(channel: channel, client: session.client)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Subscriptions")
            .searchable(text: $query, prompt: Text("Search channels"))
            .refreshable { await load() }
            .navigationDestination(for: APIModels.Channel.self) { channel in
                ChannelVideosView(channel: channel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MenuButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .overlay {
                if !loaded {
                    ProgressView()
                } else if failed {
                    ContentUnavailableView("The channels could not be loaded.", systemImage: "wifi.exclamationmark")
                } else if shown.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No subscriptions", systemImage: "person.2")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .task { await load() }
    }

    private var shown: [APIModels.Channel] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matching = needle.isEmpty ? channels : channels.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        let byName: (APIModels.Channel, APIModels.Channel) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        switch sort {
        case .name:
            return matching.sorted(by: byName)
        case .latestVideo:
            return matching.sorted { ($0.latestVideo ?? .distantPast, $1.title) > ($1.latestVideo ?? .distantPast, $0.title) }
        case .subscribedRecent:
            return matching.sorted { ($0.subscribed ?? .distantPast, $1.title) > ($1.subscribed ?? .distantPast, $0.title) }
        case .subscribers:
            return matching.sorted { $0.subscriberNumber != $1.subscriberNumber ? $0.subscriberNumber > $1.subscriberNumber : byName($0, $1) }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            channels = try await client.channels()
            failed = false
        } catch {
            failed = channels.isEmpty
        }
        loaded = true
    }
}

/// Picture, name, and "26.6M subscribers · 2 hr. ago".
private struct ChannelRow: View {
    let channel: APIModels.Channel
    let client: APIClient?

    var body: some View {
        HStack(spacing: 14) {
            ChannelPicture(source: channel.thumbnail, client: client, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: channel.title)
                    .font(.headline)
                    .lineLimit(1)
                if !details.isEmpty {
                    Text(verbatim: details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
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
struct ChannelPicture: View {
    let source: String?
    let client: APIClient?
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.circle)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: source) {
                guard let source, !source.isEmpty, let client,
                      let data = try? await client.imageData(for: source),
                      let picture = UIImage(data: data) else { return }
                image = picture
            }
    }
}

/// One channel's videos in the home screen's cards, newest first, more as
/// the end comes near. Tap plays.
struct ChannelVideosView: View {
    @Environment(AppSession.self) private var session
    let channel: APIModels.Channel
    @State private var videos: [Video] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var player = PlayerPresenter()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 22) {
                ForEach(videos) { video in
                    VideoCard(video: video, client: session.client, compact: false) {
                        guard let client = session.client else { return }
                        player.present(video: video, client: client) {} onClose: { watched in
                            if let index = videos.firstIndex(where: { $0.id == watched.id }) { videos[index] = watched }
                        }
                    }
                    .task {
                        if video.id == videos.last?.id { await loadMore() }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(Text(verbatim: channel.title))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            page = 0
            hasMore = true
            videos = []
            await loadMore()
        }
        .overlay {
            if videos.isEmpty {
                if loading || hasMore { ProgressView() } else {
                    ContentUnavailableView("No videos", systemImage: "play.rectangle")
                }
            }
        }
        .task { if videos.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard hasMore, !loading, let client = session.client else { return }
        loading = true
        defer { loading = false }
        guard let batch = try? await client.channelVideos(channel.id, page: page) else { return }
        let known = Set(videos.map(\.id))
        videos += batch.filter { !known.contains($0.id) && !$0.isShort }
        hasMore = batch.count == 40
        page += 1
    }
}
