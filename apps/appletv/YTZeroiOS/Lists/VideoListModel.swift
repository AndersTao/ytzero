import Foundation
import Observation

/// Which of the side menu's lists a screen shows.
enum VideoListKind: Sendable {
    /// The Shorts feed, cut into days as Main is.
    case shorts
    /// What is scheduled to be watched, under Today, Tomorrow and Weekend as
    /// on the web.
    case scheduled
    /// The server's recommendations, best first, in one grid: they are in
    /// order of how well they fit, so days would only scramble that.
    case recommendations
}

/// A run of cards under one heading; no title, no heading.
struct VideoSection: Identifiable {
    let id: String
    let title: String?
    let videos: [Video]
}

/// One of the side menu's lists: loading it, the next page as the grid nears
/// its end, and what is done to its videos.
@Observable
final class VideoListModel {
    let kind: VideoListKind
    private(set) var videos: [Video] = []
    private(set) var hasLoaded = false
    /// Recommendations are turned off for this profile.
    private(set) var isOff = false
    /// Set when the server stopped accepting this device's session.
    private(set) var needsSignIn = false
    /// A short confirmation shown at the bottom of the screen.
    var notice: String?

    private var page = 0
    private var hasMore = false
    private var isLoading = false
    /// Watched, rejected or taken off here: kept out even if a later answer still lists it.
    private var removed: Set<String> = []

    init(kind: VideoListKind) {
        self.kind = kind
    }

    var sections: [VideoSection] {
        switch kind {
        case .shorts:
            DayGroups.sections(videos).map { VideoSection(id: "day-\($0.daysAgo)", title: $0.title, videos: $0.videos) }
        case .scheduled:
            ScheduleGroups.sections(videos)
        case .recommendations:
            videos.isEmpty ? [] : [VideoSection(id: "all", title: nil, videos: videos)]
        }
    }

    /// From the top. `fresh` has the server work recommendations out again.
    func load(client: APIClient, fresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let (first, more) = try await fetch(client: client, page: 0, fresh: fresh)
            videos = first
            hasMore = more
            page = 1
        } catch {
            handle(error)
        }
    }

    /// The next page, once the grid nears its end.
    func videoAppeared(_ video: Video, client: APIClient) async {
        guard hasMore, !isLoading, let index = videos.firstIndex(of: video), index >= videos.count - 8 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, more) = try await fetch(client: client, page: page, fresh: false)
            hasMore = more
            page += 1
            let known = Set(videos.map(\.id))
            videos += batch.filter { !known.contains($0.id) }
        } catch {
            handle(error)
        }
    }

    private func fetch(client: APIClient, page: Int, fresh: Bool) async throws -> ([Video], Bool) {
        switch kind {
        case .shorts:
            let batch = try await client.shorts(page: page)
            return (keep(batch.filter(\.isPlayable)), batch.count == 40)
        case .scheduled:
            return (keep(try await client.watchlist()), false)
        case .recommendations:
            let answer = try await client.recommendations(page: page, refresh: fresh && page == 0)
            isOff = !answer.enabled
            return (keep(answer.videos.filter(\.isPlayable)), answer.hasMore)
        }
    }

    private func keep(_ batch: [Video]) -> [Video] {
        batch.filter { !removed.contains($0.id) }
    }

    func markWatched(_ video: Video, client: APIClient) async {
        await act(on: video, success: String(localized: "Marked as watched")) { try await client.markWatched(video.id) }
    }

    func reject(_ video: Video, client: APIClient) async {
        await act(on: video, success: String(localized: "Rejected")) { try await client.reject(video.id) }
    }

    func unschedule(_ video: Video, client: APIClient) async {
        await act(on: video, success: String(localized: "Removed from Scheduled")) { try await client.unschedule(video.id) }
    }

    /// Played to the end: it has left these lists on the server too.
    func finished(_ video: Video) {
        remove(video.id)
    }

    /// Back from the player: the card shows how far it got at once.
    func played(_ video: Video) {
        if let index = videos.firstIndex(where: { $0.id == video.id }) { videos[index] = video }
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
        videos.removeAll { $0.id == id }
    }

    private func handle(_ error: any Error) {
        if case APIError.unauthorized = error {
            needsSignIn = true
        } else if !(error is CancellationError) {
            notice = String(localized: "Something went wrong – try again")
        }
    }
}

/// Scheduled cut as the web cuts it: Today (with tonight), Tomorrow (with
/// tomorrow evening), Weekend; within each, the soonest due first.
enum ScheduleGroups {
    private static let groups: [(id: String, buckets: [String])] = [
        ("today", ["today", "tonight"]),
        ("tomorrow", ["tomorrow", "tomorrow_evening"]),
        ("weekend", ["weekend"]),
    ]
    private static let order = ["today", "tonight", "tomorrow", "tomorrow_evening", "weekend"]

    static func sections(_ videos: [Video]) -> [VideoSection] {
        var sections: [VideoSection] = groups.compactMap { group in
            let inGroup = videos.filter { group.buckets.contains($0.bucket ?? "") }
            return inGroup.isEmpty ? nil : VideoSection(id: group.id, title: title(group.id), videos: sorted(inGroup))
        }
        // A bucket this app does not know yet: last, under "Later".
        let unknown = videos.filter { !order.contains($0.bucket ?? "") }
        if !unknown.isEmpty { sections.append(VideoSection(id: "other", title: String(localized: "Later"), videos: unknown)) }
        return sections
    }

    private static func sorted(_ videos: [Video]) -> [Video] {
        videos.sorted { a, b in
            let byBucket = (order.firstIndex(of: a.bucket ?? "") ?? 0) - (order.firstIndex(of: b.bucket ?? "") ?? 0)
            if byBucket != 0 { return byBucket < 0 }
            return (a.showFrom ?? .distantPast) < (b.showFrom ?? .distantPast)
        }
    }

    private static func title(_ id: String) -> String {
        switch id {
        case "today": String(localized: "Today")
        case "tomorrow": String(localized: "Tomorrow")
        default: String(localized: "Weekend")
        }
    }
}
