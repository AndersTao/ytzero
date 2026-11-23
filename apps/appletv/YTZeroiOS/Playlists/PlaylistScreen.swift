import SwiftUI

/// One of the profile's playlists, from the side menu: all its videos in the
/// same grid and cards as Main, without the days, the last added first as the
/// web client lists them. Tap plays; touch and hold to mark as watched.
/// Pulling down loads the list again.
struct PlaylistScreen: View {
    let playlist: APIModels.UserPlaylist

    @Environment(AppSession.self) private var session
    @State private var videos: [Video] = []
    @State private var hasLoaded = false
    @State private var player = PlayerPresenter()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 22) {
                    ForEach(videos) { video in
                        card(for: video)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            // In a task of its own, as on Main: the pull's own task is
            // cancelled when the grid redraws under it.
            .refreshable { await Task { await load() }.value }
            .scrollBounceBehavior(.always)
            .overlay {
                if !hasLoaded {
                    ProgressView()
                } else if videos.isEmpty {
                    ContentUnavailableView("No videos", systemImage: "music.note.list")
                }
            }
            .navigationTitle(Text(verbatim: playlist.name))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MenuButton() }
            }
        }
        .task { await load() }
    }

    private func card(for video: Video) -> some View {
        VideoCard(video: video, client: session.client, compact: false) {
            guard let client = session.client else { return }
            player.present(video: video, client: client) {} onClose: { watched in
                // How far it got shows at once; the video stays in the playlist.
                if let index = videos.firstIndex(where: { $0.id == watched.id }) { videos[index] = watched }
            }
        }
        .contextMenu {
            Button("Mark as watched", systemImage: "eye") {
                guard let client = session.client else { return }
                Task {
                    try? await client.markWatched(video.id)
                    await load()
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        defer { hasLoaded = true }
        guard let loaded = try? await client.playlistVideos(playlist.id) else { return }
        videos = loaded
    }
}
