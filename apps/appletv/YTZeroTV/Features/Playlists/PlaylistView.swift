import SwiftUI

/// One of the profile's playlists: its videos in a grid, newest added first,
/// as the web client lists them. Select plays full screen.
struct PlaylistView: View {
    let playlist: APIModels.UserPlaylist

    @Environment(AppSession.self) private var session
    @State private var videos: [Video] = []
    @State private var hasLoaded = false
    @State private var failure: String?
    @State private var playing: Video?
    @FocusState private var focusedVideo: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4)

    var body: some View {
        ScrollView {
            // No title: the sidebar's folded button at the top left names
            // the playlist, and the first row starts below it, where Main's does.
            LazyVGrid(columns: columns, spacing: 56) {
                ForEach(videos) { video in
                    VideoCard(
                        video: video,
                        client: session.client,
                        focus: $focusedVideo,
                        play: { playing = video },
                        markWatched: { markWatched(video) }
                    )
                }
            }
            // Full width, so Down from a short row still finds the next one.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            .padding(.horizontal, 80)
            .padding(.top, 160)
            .padding(.bottom, 40)
        }
        .scrollClipDisabled()
        .overlay {
            if let failure {
                ContentUnavailableView("Could not load the playlist", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if !hasLoaded {
                ProgressView()
            } else if videos.isEmpty {
                ContentUnavailableView("No videos in this playlist", systemImage: "music.note.list")
            }
        }
        .defaultFocus($focusedVideo, videos.first?.id)
        .task(id: playlist.id) { await load() }
        .fullScreenCover(item: $playing) { video in
            PlayerView(video: video) {} onClosed: { _ in
                // The progress bars follow what was just watched.
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            videos = try await client.playlistVideos(playlist.id).filter(\.isPlayable)
            failure = nil
        } catch APIError.unauthorized {
            session.signOut()
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
        hasLoaded = true
    }

    private func markWatched(_ video: Video) {
        guard let client = session.client else { return }
        Task {
            try? await client.markWatched(video.id)
            await load()
        }
    }
}
