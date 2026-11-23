import SwiftUI

/// Shorts, Scheduled or Recommendations from the side menu: the same cards and
/// grid as Main, under the headings the kind of list has; Shorts upright, a
/// row a day that is swiped through sideways. Tap plays; touch and
/// hold for what can be done to a video. Pulling down loads the list again,
/// and for Recommendations has the server work them out anew.
struct VideoListScreen: View {
    let destination: MenuDestination

    @Environment(AppSession.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: VideoListModel
    @State private var player = PlayerPresenter()

    init(destination: MenuDestination, kind: VideoListKind) {
        self.destination = destination
        _model = State(initialValue: VideoListModel(kind: kind))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(model.sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            if let title = section.title {
                                SectionHeading(title: title, systemImage: section.systemImage)
                            }
                            if model.kind == .shorts {
                                shortsRow(section.videos)
                            } else if model.kind == .scheduled {
                                scheduledList(section.videos)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 22) {
                                    ForEach(section.videos) { video in
                                        card(for: video)
                                            .task { await appeared(video) }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            // In a task of its own, as on Main: the pull's own task is
            // cancelled when the grid redraws under it.
            .refreshable {
                guard let client = session.client else { return }
                await Task { await model.load(client: client, fresh: true) }.value
            }
            .scrollBounceBehavior(.always)
            .overlay { emptyState }
            .overlay(alignment: .bottom) { noticeView }
            .navigationTitle(Text(verbatim: destination.title))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MenuButton() }
            }
        }
        .task {
            guard let client = session.client else { return }
            await model.load(client: client)
        }
        .onChange(of: model.needsSignIn) { _, needsSignIn in
            if needsSignIn { session.signOut() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.hasLoaded {
            ProgressView()
        } else if model.videos.isEmpty {
            switch model.kind {
            case .shorts:
                ContentUnavailableView("No new Shorts", systemImage: destination.systemImage)
            case .scheduled:
                ContentUnavailableView("Nothing scheduled", systemImage: destination.systemImage,
                                       description: Text("Videos you schedule on the web are listed here."))
            case .recommendations where model.isOff:
                ContentUnavailableView("Recommendations are off", systemImage: destination.systemImage,
                                       description: Text("They can be turned on in Settings on the web."))
            case .recommendations:
                ContentUnavailableView("No recommendations yet", systemImage: destination.systemImage,
                                       description: Text("Pull down to have the server look again."))
            }
        }
    }

    /// A day's Shorts in one row of upright cards, swiped through sideways
    /// as YouTube's own app shows them.
    private func shortsRow(_ videos: [Video]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(videos) { video in
                    card(for: video, tall: true)
                        .frame(width: horizontalSizeClass == .regular ? 210 : 165)
                        .task { await appeared(video) }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }

    /// Scheduled as the web lists it: a row a video, with the times it can
    /// be moved to and a cross that takes it off.
    private func scheduledList(_ videos: [Video]) -> some View {
        VStack(spacing: 0) {
            ForEach(videos) { video in
                ScheduledRow(video: video, client: session.client) {
                    play(video)
                } move: { bucket in
                    run { client in await model.reschedule(video, to: bucket, client: client) }
                } remove: {
                    run { client in await model.unschedule(video, client: client) }
                }
                .padding(.vertical, 12)
                .contextMenu {
                    DownloadMenuItem(video: video, client: session.client)
                    Button("Mark as watched", systemImage: "eye") {
                        run { client in await model.markWatched(video, client: client) }
                    }
                }
                Divider()
            }
        }
        .padding(.horizontal)
    }

    private func play(_ video: Video) {
        guard let client = session.client else { return }
        player.present(video: video, client: client) {
            model.finished(video)
        } onClose: { watched in
            model.played(watched)
        }
    }

    private func appeared(_ video: Video) async {
        guard let client = session.client else { return }
        await model.videoAppeared(video, client: client)
    }

    private func card(for video: Video, tall: Bool = false) -> some View {
        VideoCard(video: video, client: session.client, compact: tall, tall: tall) {
            play(video)
        }
        .contextMenu {
            DownloadMenuItem(video: video, client: session.client)
            Button("Mark as watched", systemImage: "eye") {
                run { client in await model.markWatched(video, client: client) }
            }
            if model.kind == .scheduled {
                Button("Remove from Scheduled", systemImage: "calendar.badge.minus") {
                    run { client in await model.unschedule(video, client: client) }
                }
            } else {
                Button("Reject", systemImage: "xmark.circle", role: .destructive) {
                    run { client in await model.reject(video, client: client) }
                }
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

/// A heading with a line to the edge, as Main's days have, and a symbol
/// before it where the list has one.
struct SectionHeading: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: title)
            }
            .font(.title3.bold())
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("section-heading")
    }
}
