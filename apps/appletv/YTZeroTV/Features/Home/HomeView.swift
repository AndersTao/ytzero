import SwiftUI

/// Continue watching and Main, nothing else. Select plays full screen.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    @State private var model = HomeModel()
    @State private var playing: Video?
    @State private var showingSettings = false
    @FocusState private var focusedVideo: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                header
                if !model.continueWatching.isEmpty {
                    continueShelf
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
            await model.loadFirstPage(client: client)
            focusedVideo = firstVideoID
        }
        .onChange(of: model.needsSignIn) { _, needsSignIn in
            if needsSignIn { session.signOut() }
        }
        .fullScreenCover(item: $playing, onDismiss: reloadShelf) { video in
            PlayerView(video: video) { model.finished(video) }
        }
        .confirmationDialog("Settings", isPresented: $showingSettings) {
            Button("Sign out", role: .destructive) { session.signOut() }
            Button("Use another server", role: .destructive) { session.forgetServer() }
        }
    }

    private var header: some View {
        HStack {
            Text("YT Zero")
                .font(.title2.bold())
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") {
                run { client in await model.refresh(client: client) }
            }
            .disabled(model.isRefreshing)
            Button("Settings", systemImage: "gearshape") {
                showingSettings = true
            }
            .labelStyle(.iconOnly)
        }
    }

    private var continueShelf: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Continue watching")
                .font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(model.continueWatching) { video in
                        card(for: video)
                            .containerRelativeFrame(.horizontal, count: 4, spacing: 48)
                    }
                }
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }

    private var mainGrid: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !model.continueWatching.isEmpty {
                Text("Main")
                    .font(.headline)
            }
            LazyVGrid(columns: columns, spacing: 56) {
                ForEach(model.main) { video in
                    card(for: video)
                        .task {
                            guard let client = session.client else { return }
                            await model.videoAppeared(video, client: client)
                        }
                }
            }
        }
    }

    /// Where the remote starts: the first video, not the Refresh button.
    private var firstVideoID: String? {
        model.continueWatching.first?.id ?? model.main.first?.id
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

    private func reloadShelf() {
        run { client in await model.loadContinue(client: client) }
    }

    private func run(_ action: @escaping (APIClient) async -> Void) {
        guard let client = session.client else { return }
        Task { await action(client) }
    }
}
