import SwiftUI

/// Continue watching and Main. Tap plays; touch and hold to mark as watched or
/// reject. Pulling down has the server check the channels for new videos,
/// then reloads the lists.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HomeModel()
    @State private var player = PlayerPresenter()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !model.continueWatching.isEmpty {
                        continueShelf
                    }
                    mainGrid
                }
                .padding(.vertical, 12)
            }
            // Pulling down does what Refresh does: the server checks the
            // channels for new videos, then the lists load again, with the
            // same notice. It used to reload the lists only, which changed
            // nothing visible and looked like it did not work.
            //
            // In a task of its own that the pull only waits for: SwiftUI
            // cancels the pull's task when the lists redraw under it, which
            // cut the server's check off halfway and left the lists as they
            // were.
            .refreshable {
                guard let client = session.client else { return }
                await Task { await model.refresh(client: client) }.value
            }
            // Also when everything fits on one screen.
            .scrollBounceBehavior(.always)
            .overlay {
                if model.hasLoaded && model.main.isEmpty && model.continueWatching.isEmpty {
                    ContentUnavailableView("No new videos", systemImage: "checkmark.circle")
                } else if !model.hasLoaded {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottom) { noticeView }
            // The name sits on the same row as the buttons rather than a large
            // title under them, which left a band of empty bar above the lists.
            .navigationBarTitleDisplayMode(.inline)
            // Who is watching and Settings are at the bottom of the side menu.
            .toolbar { titleItem }
        }
        .task {
            guard let client = session.client else { return }
            await model.loadFirstPage(client: client)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isStale, !player.isPresenting {
                run { client in await model.loadFirstPage(client: client) }
            }
        }
        .onChange(of: model.needsSignIn) { _, needsSignIn in
            if needsSignIn { session.signOut() }
        }
    }

    @ToolbarContentBuilder
    private var titleItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { MenuButton() }
        if #available(iOS 26, *) {
            // Plain text, not a button in a glass capsule.
            ToolbarItem(placement: .topBarLeading) { appName }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { appName }
        }
    }

    private var appName: some View {
        Text("YT Zero")
            .font(.title.bold())
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var continueShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue watching")
                .font(.title3.bold())
                .padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.continueWatching) { video in
                        card(for: video, compact: true)
                            .frame(width: 260)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A heading for each day with a line to the edge, as "Main" had,
    /// and the day's videos under it.
    private var mainGrid: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(model.mainByDay) { day in
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: day.title)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 22) {
                        ForEach(day.videos) { video in
                            card(for: video, compact: false)
                                .task {
                                    guard let client = session.client else { return }
                                    await model.videoAppeared(video, client: client)
                                }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func card(for video: Video, compact: Bool) -> some View {
        VideoCard(video: video, client: session.client, compact: compact) {
            guard let client = session.client else { return }
            player.present(video: video, client: client) {
                model.finished(video)
            } onClose: { watched in
                model.played(watched)
                run { client in await model.loadContinue(client: client) }
            }
        }
        .contextMenu {
            DownloadMenuItem(video: video, client: session.client)
            Button("Mark as watched", systemImage: "eye") {
                run { client in await model.markWatched(video, client: client) }
            }
            Button("Reject", systemImage: "xmark.circle", role: .destructive) {
                run { client in await model.reject(video, client: client) }
            }
        }
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 24)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    if model.notice == notice { model.notice = nil }
                }
        }
    }

    private func run(_ action: @escaping (APIClient) async -> Void) {
        guard let client = session.client else { return }
        Task { await action(client) }
    }
}
