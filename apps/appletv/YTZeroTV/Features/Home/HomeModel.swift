import Foundation
import Observation

/// The two shelves on the home screen and what can be done to their videos.
@Observable
final class HomeModel {
    private(set) var continueWatching: [Video] = []
    private(set) var main: [Video] = []
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    /// A short confirmation shown at the bottom of the screen.
    var notice: String?
    /// Set when the server stopped accepting this Apple TV's session.
    private(set) var needsSignIn = false

    private var page = 0
    private var hasMore = true
    /// Watched or rejected here: kept out even if a later answer still lists it.
    private var removed: Set<String> = []

    private static let pageSize = 40

    func loadFirstPage(client: APIClient) async {
        page = 0
        hasMore = true
        main = []
        await loadContinue(client: client)
        await loadMore(client: client)
        hasLoaded = true
    }

    func loadContinue(client: APIClient) async {
        do {
            let videos = try await client.inProgress()
            continueWatching = videos.filter { $0.isPlayable && !$0.isShort && !removed.contains($0.id) }
            // As in the web client, a video on the shelf is not repeated below.
            let shelf = Set(continueWatching.map(\.id))
            main.removeAll { shelf.contains($0.id) }
        } catch {
            handle(error)
        }
    }

    func loadMore(client: APIClient) async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let batch = try await client.feed(page: page)
            hasMore = batch.count == Self.pageSize
            page += 1
            let known = Set(main.map(\.id)).union(continueWatching.map(\.id))
            main += batch.filter { $0.isPlayable && !known.contains($0.id) && !removed.contains($0.id) }
        } catch {
            handle(error)
        }
    }

    /// Load the next page once the grid nears its end.
    func videoAppeared(_ video: Video, client: APIClient) async {
        guard let index = main.firstIndex(of: video), index >= main.count - 8 else { return }
        await loadMore(client: client)
    }

    func refresh(client: APIClient) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        notice = String(localized: "Refreshing…")
        let added = try? await client.refreshSubscriptions()
        await loadFirstPage(client: client)
        notice = switch added {
        case .some(0): String(localized: "Up to date · no new videos")
        case .some(let count): String(localized: "Updated · \(count) new videos")
        case .none: String(localized: "Updated")
        }
    }

    func markWatched(_ video: Video, client: APIClient) async {
        await act(on: video, success: String(localized: "Marked as watched")) { try await client.markWatched(video.id) }
    }

    func reject(_ video: Video, client: APIClient) async {
        await act(on: video, success: String(localized: "Rejected")) { try await client.reject(video.id) }
    }

    /// The player finished the video: it leaves both shelves.
    func finished(_ video: Video) {
        remove(video.id)
    }

    private func act(on video: Video, success: String, _ action: () async throws -> Void) async {
        do {
            try await action()
            remove(video.id)
            notice = success
        } catch {
            handle(error)
        }
    }

    private func remove(_ id: String) {
        removed.insert(id)
        continueWatching.removeAll { $0.id == id }
        main.removeAll { $0.id == id }
    }

    private func handle(_ error: any Error) {
        if case APIError.unauthorized = error {
            needsSignIn = true
        } else if !(error is CancellationError) {
            notice = String(localized: "Something went wrong – try again")
        }
    }
}
