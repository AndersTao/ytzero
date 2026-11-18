import SwiftUI

/// Continue watching and Main. Tap plays; touch and hold to mark as watched or
/// reject. Pull down reloads the lists; the toolbar button also has the server
/// check the channels, which takes it half a minute.
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
            .refreshable {
                guard let client = session.client else { return }
                await model.loadFirstPage(client: client)
            }
            .overlay {
                if model.hasLoaded && model.main.isEmpty && model.continueWatching.isEmpty {
                    ContentUnavailableView("No new videos", systemImage: "checkmark.circle")
                } else if !model.hasLoaded {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottom) { noticeView }
            .navigationTitle("YT Zero")
            .toolbar { toolbar }
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
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                run { client in await model.refresh(client: client) }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            Menu {
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { session.signOut() }
                Button("Use another server", systemImage: "server.rack", role: .destructive) { session.forgetServer() }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
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

    private var mainGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.continueWatching.isEmpty {
                // As on the TV: a line from the title to the edge keeps what
                // is under way apart from everything else.
                HStack(spacing: 14) {
                    Text("Main")
                        .font(.title3.bold())
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(height: 1)
                }
                .padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 22) {
                ForEach(model.main) { video in
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
