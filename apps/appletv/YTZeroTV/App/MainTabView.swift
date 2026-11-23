import SwiftUI

/// The places of the app in the system sidebar, as the iPhone and iPad side
/// menu has them: Main, Recommendations, Shorts, Scheduled, Subscriptions
/// (still to come), and the profile's own
/// playlists in a section of their own. The sidebar folds away to a button
/// at the top left naming the place; Up from the top of a screen opens it,
/// and Select on a place shows that place and folds it away again.
struct MainTabView: View {
    enum Place: Hashable {
        case main
        case recommendations
        case shorts
        case scheduled
        case subscriptions
        case playlist(Int)
    }

    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Place = .main
    @State private var playlists: [APIModels.UserPlaylist] = []
    @State private var home = HomeModel()
    /// A video the Top Shelf asked to play.
    @State private var playRequest: String?

    var body: some View {
        // At launch the sidebar shows for a moment and then folds away onto
        // the screen beside it, but only if that screen has something to
        // focus, and not if its places change meanwhile. So Main and the
        // playlists are loaded first, and the remote ends up on the first video.
        Group {
            if home.hasLoaded {
                tabs
            } else {
                ProgressView()
                    .task {
                        guard let client = session.client else { return }
                        async let playlistsLoaded: Void = loadPlaylists()
                        await home.loadFirstPage(client: client)
                        await playlistsLoaded
                        if home.needsSignIn { session.signOut() }
                    }
            }
        }
        // Select or Play on the Top Shelf: Main plays the video, also when
        // the app was not running and is still loading.
        .onOpenURL { url in
            guard let id = TopShelfSnapshot.videoID(from: url) else { return }
            selection = .main
            playRequest = id
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Main", systemImage: "house", value: Place.main) {
                HomeView(model: home, playRequest: $playRequest)
            }
            Tab("Recommendations", systemImage: "sparkles", value: Place.recommendations) {
                VideoListView(kind: .recommendations, systemImage: "sparkles")
            }
            Tab("Shorts", systemImage: "play.rectangle.on.rectangle", value: Place.shorts) {
                VideoListView(kind: .shorts, systemImage: "play.rectangle.on.rectangle")
            }
            Tab("Scheduled", systemImage: "clock", value: Place.scheduled) {
                VideoListView(kind: .scheduled, systemImage: "clock")
            }
            Tab("Subscriptions", systemImage: "person.2", value: Place.subscriptions) {
                ComingSoonView(title: "Subscriptions", systemImage: "person.2")
            }
            if !playlists.isEmpty {
                TabSection("My playlists") {
                    ForEach(playlists) { playlist in
                        // The name as written on the web, not looked up as a key.
                        Tab(playlist.name, systemImage: "music.note.list", value: Place.playlist(playlist.id)) {
                            PlaylistView(playlist: playlist)
                        }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: scenePhase) { _, phase in
            // A playlist made on the web meanwhile shows up when the app is back.
            if phase == .active { Task { await loadPlaylists() } }
        }
    }

    private func loadPlaylists() async {
        guard let client = session.client, let loaded = try? await client.playlists() else { return }
        playlists = loaded
        // The playlist on screen was deleted elsewhere: back to Main.
        if case .playlist(let id) = selection, !loaded.contains(where: { $0.id == id }) {
            selection = .main
        }
    }
}

/// A place the sidebar has whose screen is still to be made.
struct ComingSoonView: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("Coming soon")
        }
    }
}
