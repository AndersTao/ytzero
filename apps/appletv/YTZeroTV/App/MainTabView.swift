import SwiftUI

/// The places of the app in the system sidebar, as the iPhone and iPad side
/// menu has them: Main, Recommendations, Shorts, Scheduled, Subscriptions,
/// and the profile's own playlists in a section of their own. The sidebar
/// folds away to a button at the top left naming the place; Up from the top
/// of a screen opens it, and Select on a place shows that place and folds it
/// away again.
///
/// Who is watching and Refresh sit at the top of the sidebar (tvOS 27), so
/// they are there on every screen and Up from a screen's first row goes
/// straight to the places, as on the LG TV. Before tvOS 27 a sidebar has no
/// room for them, and each screen keeps them in a header of its own.
struct MainTabView: View {
    enum Place: Hashable {
        case main
        case recommendations
        case shorts
        case scheduled
        case subscriptions
        case playlist(Int)
    }

    /// Whether the sidebar holds Refresh and the profile picture.
    static var sidebarHasHeader: Bool {
        if #available(tvOS 27, *) { true } else { false }
    }

    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Place = .main
    @State private var playlists: [APIModels.UserPlaylist] = []
    @State private var home = HomeModel()
    @State private var profiles = ProfilesModel()
    @State private var showingProfiles = false
    /// Raised by the sidebar's Refresh: the place on screen reloads.
    @State private var refreshSignals: [Place: Int] = [:]
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
        // Who is watching, for the profile picture: names and pictures come from the server.
        .task { await profiles.load(session: session) }
        // Select or Play on the Top Shelf: Main plays the video, also when
        // the app was not running and is still loading.
        .onOpenURL { url in
            guard let id = TopShelfSnapshot.videoID(from: url) else { return }
            selection = .main
            playRequest = id
        }
        // "Who is watching?" on the whole screen, as the Apple TV's own apps ask it.
        .fullScreenCover(isPresented: $showingProfiles) {
            ProfilePickerView(model: profiles)
                .environment(session)
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Main", systemImage: "house", value: Place.main) {
                HomeView(model: home, playRequest: $playRequest, refreshSignal: signal(.main), header: screenHeader(for: .main))
            }
            Tab("Recommendations", systemImage: "sparkles", value: Place.recommendations) {
                VideoListView(kind: .recommendations, systemImage: "sparkles", refreshSignal: signal(.recommendations), header: screenHeader(for: .recommendations))
            }
            Tab("Shorts", systemImage: "play.rectangle.on.rectangle", value: Place.shorts) {
                VideoListView(kind: .shorts, systemImage: "play.rectangle.on.rectangle", refreshSignal: signal(.shorts), header: screenHeader(for: .shorts))
            }
            Tab("Scheduled", systemImage: "clock", value: Place.scheduled) {
                VideoListView(kind: .scheduled, systemImage: "clock", refreshSignal: signal(.scheduled), header: screenHeader(for: .scheduled))
            }
            Tab("Subscriptions", systemImage: "person.2", value: Place.subscriptions) {
                SubscriptionsView(refreshSignal: signal(.subscriptions), header: screenHeader(for: .subscriptions))
            }
            if !playlists.isEmpty {
                TabSection("My playlists") {
                    ForEach(playlists) { playlist in
                        Tab(value: Place.playlist(playlist.id)) {
                            PlaylistView(playlist: playlist, refreshSignal: signal(.playlist(playlist.id)))
                        } label: {
                            // The name as written on the web, not looked up as
                            // a key, and how many videos it holds, as the LG TV shows.
                            Label {
                                Text(verbatim: "\(playlist.name)  \(playlist.videoCount)")
                            } icon: {
                                Image(systemName: "music.note.list")
                            }
                        }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sidebarHeader { sidebarHeader }
        .onChange(of: scenePhase) { _, phase in
            // A playlist made on the web meanwhile shows up when the app is back.
            if phase == .active { Task { await loadPlaylists() } }
        }
    }

    /// Who is watching and Refresh, at the top of the sidebar.
    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button {
                showingProfiles = true
            } label: {
                HStack(spacing: 20) {
                    profileBadge(size: 56)
                    Text(verbatim: session.activeProfile?.name ?? "")
                        .lineLimit(1)
                }
            }
            .accessibilityHint(Text("Switch profile"))
            .accessibilityIdentifier("profile-button")
            Button {
                refresh(selection)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("refresh-button")
        }
        .padding(.bottom, 12)
    }

    /// The header a screen shows itself before tvOS 27; nil when the sidebar has it.
    private func screenHeader(for place: Place) -> ScreenHeader? {
        guard !Self.sidebarHasHeader else { return nil }
        return ScreenHeader(
            refresh: { refresh(place) },
            showProfiles: place == .main ? { showingProfiles = true } : nil
        )
    }

    private func signal(_ place: Place) -> Int {
        refreshSignals[place, default: 0]
    }

    private func refresh(_ place: Place) {
        refreshSignals[place, default: 0] += 1
        if case .playlist = place { Task { await loadPlaylists() } }
    }

    @ViewBuilder
    private func profileBadge(size: CGFloat) -> some View {
        if let profile = session.activeProfile {
            ProfileAvatar(name: profile.name, avatar: profile.avatar, color: profile.avatarColor, client: session.client, size: size)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
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

/// What a screen's own header does, before tvOS 27 put it in the sidebar:
/// Refresh, and on Main the profile picture.
struct ScreenHeader {
    let refresh: () -> Void
    let showProfiles: (() -> Void)?
}

private extension View {
    /// Content at the top of the sidebar, where tvOS has room for it (27 and later).
    @ViewBuilder
    func sidebarHeader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(tvOS 27, *) {
            tabViewSidebarHeader(content: content)
        } else {
            self
        }
    }
}
