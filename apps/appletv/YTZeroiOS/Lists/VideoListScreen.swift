import SwiftUI

/// Shorts, Scheduled or Recommendations from the side menu: the same cards and
/// grid as Main, under the headings the kind of list has. Tap plays; touch and
/// hold for what can be done to a video. Pulling down loads the list again,
/// and for Recommendations has the server work them out anew.
struct VideoListScreen: View {
    let destination: MenuDestination

    @Environment(AppSession.self) private var session
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
                                SectionHeading(title: title)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 22) {
                                ForEach(section.videos) { video in
                                    card(for: video)
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

    private func card(for video: Video) -> some View {
        VideoCard(video: video, client: session.client, compact: false) {
            guard let client = session.client else { return }
            player.present(video: video, client: client) {
                model.finished(video)
            } onClose: { watched in
                model.played(watched)
            }
        }
        .contextMenu {
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

/// A heading with a line to the edge, as Main's days have.
struct SectionHeading: View {
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: title)
                .font(.title3.bold())
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
