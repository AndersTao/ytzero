import SwiftUI

/// Continue watching, Saved for later and Main. Select plays full screen.
/// Up from the top row reaches the sidebar (tvOS 27, where it holds Refresh
/// and the profile picture), or before that a header of its own first.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    /// Loaded by the tab view before it shows: see MainTabView.
    let model: HomeModel
    /// A video to play as soon as it is found, e.g. from the Top Shelf.
    @Binding var playRequest: String?
    /// Raised by the sidebar's Refresh.
    let refreshSignal: Int
    /// Refresh and the profile picture on the screen itself, before tvOS 27.
    let header: ScreenHeader?
    @State private var playing: Video?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedVideo: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                if let header {
                    headerView(header)
                }
                if !model.continueWatching.isEmpty {
                    shelf("Continue watching", videos: model.continueWatching)
                }
                if !model.savedForLater.isEmpty {
                    shelf("Saved for later", videos: model.savedForLater)
                }
                mainGrid
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .overlay(alignment: .bottom) { noticeView }
        .overlay {
            if model.hasLoaded && model.main.isEmpty && model.continueWatching.isEmpty {
                ContentUnavailableView("No new videos", systemImage: "checkmark.circle")
            } else if !model.hasLoaded {
                ProgressView()
            }
        }
        .defaultFocus($focusedVideo, firstVideoID)
        .task {
            guard let client = session.client else { return }
            if !model.hasLoaded { await model.loadFirstPage(client: client) }
            focusedVideo = firstVideoID
        }
        .onChange(of: refreshSignal) {
            run { client in await model.refresh(client: client) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isStale, playing == nil {
                run { client in await model.loadFirstPage(client: client) }
            }
        }
        // What the Top Shelf shows follows the shelves.
        .task(id: topShelfKey) {
            guard let client = session.client else { return }
            await TopShelfPublisher.publish(continueWatching: model.continueWatching, savedForLater: model.savedForLater, main: model.main, client: client)
        }
        .task(id: playRequest) { await playRequested() }
        .onChange(of: model.needsSignIn) { _, needsSignIn in
            if needsSignIn { session.signOut() }
        }
        .fullScreenCover(item: $playing) { video in
            PlayerView(video: video) {
                model.finished(video)
            } onClosed: { watched in
                // Only now: asked while the position was still being saved,
                // the server answered with the old one.
                model.played(watched)
                reloadShelf()
            }
        }
    }

    @ViewBuilder
    private var profileBadge: some View {
        if let profile = session.activeProfile {
            ProfileAvatar(name: profile.name, avatar: profile.avatar, color: profile.avatarColor, client: session.client, size: 64)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
    }

    /// Refresh and who is watching, at the right, before tvOS 27. No title:
    /// the sidebar's folded button at the top left already names the place.
    private func headerView(_ header: ScreenHeader) -> some View {
        HStack(spacing: 28) {
            Spacer()
            // Never disabled: the server takes half a minute to check the
            // channels, and a focused button that turns disabled leaves the
            // remote with nothing to move. A second press is ignored instead.
            Button {
                header.refresh()
            } label: {
                if model.isRefreshing {
                    Label { Text("Refreshing…") } icon: { ProgressView() }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            // Who is watching, at the far right: the picture itself opens the
            // list of profiles to switch to.
            Button {
                header.showProfiles?()
            } label: {
                profileBadge
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(session.activeProfile?.name.isEmpty == false ? session.activeProfile!.name : String(localized: "Profiles")))
            .accessibilityHint(Text("Switch profile"))
            .accessibilityIdentifier("profile-button")
        }
        // Its own focus section: Up from any card in the grid lands here, not
        // only from a card that happens to sit below a button.
        .focusSection()
    }

    /// A row of four cards across under a title: Continue watching, Saved for later.
    private func shelf(_ title: LocalizedStringKey, videos: [Video]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(videos) { video in
                        card(for: video)
                            .containerRelativeFrame(.horizontal, count: 4, spacing: 48)
                    }
                }
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
        // Full width and a focus section of its own, as is Main below: Down
        // from the header buttons at the right edge looks straight down, and
        // a short row has no card there. A section takes it from anywhere above.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// A heading for each day with a line to the edge, as "Main" had, and
    /// the day's videos under it. Each day is a full-width focus section of
    /// its own, so Down from a short row still reaches the next day.
    private var mainGrid: some View {
        VStack(alignment: .leading, spacing: 56) {
            ForEach(model.mainByDay) { day in
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 28) {
                        Text(verbatim: day.title)
                            .font(.headline)
                        Rectangle()
                            .fill(.white.opacity(0.18))
                            .frame(height: 2)
                    }
                    LazyVGrid(columns: columns, spacing: 56) {
                        ForEach(day.videos) { video in
                            card(for: video)
                                .task {
                                    guard let client = session.client else { return }
                                    await model.videoAppeared(video, client: client)
                                }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the remote starts: the first video, not the Refresh button.
    private var firstVideoID: String? {
        model.continueWatching.first?.id ?? model.savedForLater.first?.id ?? model.main.first?.id
    }

    private func card(for video: Video) -> some View {
        VideoCard(
            video: video,
            client: session.client,
            focus: $focusedVideo,
            play: { playing = video },
            markWatched: { run { client in await model.markWatched(video, client: client) } },
            reject: { run { client in await model.reject(video, client: client) } }
        )
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.headline)
                .padding(.horizontal, 40)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 40)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    if model.notice == notice { model.notice = nil }
                }
        }
    }

    /// Changes when a video on the Top Shelf would change: which, and how far watched.
    private var topShelfKey: [String] {
        (model.continueWatching + model.savedForLater.prefix(10) + model.main.prefix(10)).map { "\($0.id) \(Int(($0.progress ?? 0) * 100))" }
    }

    /// Plays the video asked for, looking for it again in Continue watching
    /// when it is not on screen (watched further elsewhere since).
    private func playRequested() async {
        guard let id = playRequest, let client = session.client else { return }
        var video = (model.continueWatching + model.savedForLater + model.main).first { $0.id == id }
        if video == nil {
            await model.loadContinue(client: client)
            video = model.continueWatching.first { $0.id == id }
        }
        playRequest = nil
        guard let video else {
            model.notice = String(localized: "That video is no longer here.")
            return
        }
        playing = video
    }

    private func reloadShelf() {
        run { client in await model.loadContinue(client: client) }
    }

    private func run(_ action: @escaping (APIClient) async -> Void) {
        guard let client = session.client else { return }
        Task { await action(client) }
    }
}
