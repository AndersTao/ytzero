import SwiftUI

/// Shorts, Scheduled or Recommendations from the sidebar, as the iPhone and
/// iPad have them: Main's cards in a grid of four, under the headings the
/// kind of list has; Shorts upright, a row a day. Select plays full screen; touch and hold for what can be
/// done to a video. Refresh loads the list again, and for Recommendations has
/// the server work them out anew.
struct VideoListView: View {
    @Environment(AppSession.self) private var session
    @State private var model: VideoListModel
    @State private var playing: Video?
    @FocusState private var focusedVideo: String?
    private let systemImage: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4)

    init(kind: VideoListKind, systemImage: String) {
        _model = State(initialValue: VideoListModel(kind: kind))
        self.systemImage = systemImage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                header
                // Each heading's grid is a full-width focus section of its
                // own, as Main's days are, so Down from a short row still
                // reaches the next one.
                VStack(alignment: .leading, spacing: 56) {
                    ForEach(model.sections) { section in
                        VStack(alignment: .leading, spacing: 24) {
                            if let title = section.title {
                                HStack(spacing: 28) {
                                    HStack(spacing: 14) {
                                        if let systemImage = section.systemImage {
                                            Image(systemName: systemImage)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(verbatim: title)
                                    }
                                    .font(.headline)
                                    Rectangle()
                                        .fill(.white.opacity(0.18))
                                        .frame(height: 2)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isHeader)
                            }
                            if model.kind == .shorts {
                                shortsRow(section.videos)
                            } else if model.kind == .scheduled {
                                VStack(alignment: .leading, spacing: 32) {
                                    ForEach(section.videos) { video in
                                        ScheduledRow(
                                            video: video,
                                            client: session.client,
                                            focus: $focusedVideo,
                                            play: { playing = video },
                                            markWatched: { run { client in await model.markWatched(video, client: client) } },
                                            move: { bucket in run { client in await model.reschedule(video, to: bucket, client: client) } },
                                            remove: { run { client in await model.unschedule(video, client: client) } }
                                        )
                                    }
                                }
                            } else {
                                LazyVGrid(columns: columns, spacing: 56) {
                                    ForEach(section.videos) { video in
                                        card(for: video)
                                            .task { await appeared(video) }
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
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .overlay { emptyState }
        .overlay(alignment: .bottom) { noticeView }
        .defaultFocus($focusedVideo, model.videos.first?.id)
        .task {
            guard let client = session.client else { return }
            await model.load(client: client)
            focusedVideo = model.videos.first?.id
        }
        .onChange(of: model.needsSignIn) { _, needsSignIn in
            if needsSignIn { session.signOut() }
        }
        .fullScreenCover(item: $playing) { video in
            PlayerView(video: video) {
                model.finished(video)
            } onClosed: { watched in
                model.played(watched)
            }
        }
    }

    /// Refresh at the right. No title: the sidebar's folded button at the top
    /// left already names the place.
    private var header: some View {
        HStack {
            Spacer()
            Button {
                run { client in await model.load(client: client, fresh: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.hasLoaded {
            ProgressView()
        } else if model.videos.isEmpty {
            switch model.kind {
            case .shorts:
                ContentUnavailableView("No new Shorts", systemImage: systemImage)
            case .scheduled:
                ContentUnavailableView("Nothing scheduled", systemImage: systemImage,
                                       description: Text("Videos you schedule on the web are listed here."))
            case .recommendations where model.isOff:
                ContentUnavailableView("Recommendations are off", systemImage: systemImage,
                                       description: Text("They can be turned on in Settings on the web."))
            case .recommendations:
                ContentUnavailableView("No recommendations yet", systemImage: systemImage,
                                       description: Text("Press Refresh to have the server look again."))
            }
        }
    }

    /// A day's Shorts in one row of upright cards, six to the width of the
    /// screen; Right moves along it, as YouTube's own app shows them.
    private func shortsRow(_ videos: [Video]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 40) {
                ForEach(videos) { video in
                    card(for: video, tall: true)
                        .containerRelativeFrame(.horizontal, count: 6, spacing: 40)
                        .task { await appeared(video) }
                }
            }
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
    }

    private func appeared(_ video: Video) async {
        guard let client = session.client else { return }
        await model.videoAppeared(video, client: client)
    }

    private func card(for video: Video, tall: Bool = false) -> some View {
        VideoCard(
            video: video,
            client: session.client,
            focus: $focusedVideo,
            play: { playing = video },
            markWatched: { run { client in await model.markWatched(video, client: client) } },
            reject: model.kind == .scheduled ? nil : { run { client in await model.reject(video, client: client) } },
            unschedule: model.kind == .scheduled ? { run { client in await model.unschedule(video, client: client) } } : nil,
            tall: tall
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

    private func run(_ action: @escaping (APIClient) async -> Void) {
        guard let client = session.client else { return }
        Task { await action(client) }
    }
}
