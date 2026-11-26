import Foundation

/// A video as the YT Zero API returns it, reduced to what this app shows.
nonisolated struct Video: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
    let thumbnail: String?
    var watchPosition: Double?
    var watchDuration: Double?
    let isShort: Bool
    let isUnavailable: Bool
    let isPrivate: Bool
    let liveStatus: String?
    /// As the server stores it: usually "12:34" or "1:02:03".
    let duration: String?
    let publishedAt: Date?
    /// When it is scheduled to be watched: "today", "tonight", "tomorrow",
    /// "tomorrow_evening" or "weekend"; nil when it is not.
    let bucket: String?
    /// From when a scheduled video is due.
    let showFrom: Date?
    /// How often it was watched on YouTube, when the server knows.
    let views: Int?
    /// The channel's picture, for the Shorts cards.
    let channelThumbnail: String?

    enum CodingKeys: String, CodingKey {
        case id = "video_id"
        case title
        case channelTitle = "channel_title"
        case thumbnail
        case watchPosition = "watch_position"
        case watchDuration = "watch_duration"
        case isShort = "is_short"
        case isUnavailable = "is_unavailable"
        case isPrivate = "is_private"
        case liveStatus = "live_status"
        case duration
        case publishedAt = "published_at"
        case bucket
        case showFrom = "show_from"
        case views
        case channelThumbnail = "channel_thumbnail"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        channelTitle = try container.decodeIfPresent(String.self, forKey: .channelTitle) ?? ""
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        watchPosition = try container.decodeIfPresent(Double.self, forKey: .watchPosition)
        watchDuration = try container.decodeIfPresent(Double.self, forKey: .watchDuration)
        isShort = (try? container.decodeIfPresent(Int.self, forKey: .isShort)) == 1
        isUnavailable = (try? container.decodeIfPresent(Int.self, forKey: .isUnavailable)) == 1
        isPrivate = (try? container.decodeIfPresent(Int.self, forKey: .isPrivate)) == 1
        liveStatus = try container.decodeIfPresent(String.self, forKey: .liveStatus)
        duration = try? container.decodeIfPresent(String.self, forKey: .duration)
        publishedAt = (try? container.decodeIfPresent(String.self, forKey: .publishedAt)).flatMap(Self.parseTimestamp)
        bucket = try? container.decodeIfPresent(String.self, forKey: .bucket)
        showFrom = (try? container.decodeIfPresent(String.self, forKey: .showFrom)).flatMap(Self.parseTimestamp)
        views = try? container.decodeIfPresent(Int.self, forKey: .views)
        channelThumbnail = (try? container.decodeIfPresent(String.self, forKey: .channelThumbnail)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A video the server looked up by its id (`APIClient.videoInfo`), which
    /// carries no position and is not a short.
    init(info: APIModels.VideoInfo) {
        id = info.videoId
        title = info.title
        channelTitle = info.channelTitle
        thumbnail = info.thumbnail
        watchPosition = nil
        watchDuration = nil
        isShort = false
        isUnavailable = false
        isPrivate = false
        liveStatus = info.liveStatus
        duration = info.duration
        publishedAt = info.publishedAt.flatMap(Self.parseTimestamp)
        bucket = nil
        showFrom = nil
        views = nil
        channelThumbnail = nil
    }

    /// Written back as the server sends it, so a video kept for offline
    /// viewing reads the same way when it is loaded again.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(channelTitle, forKey: .channelTitle)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encodeIfPresent(watchPosition, forKey: .watchPosition)
        try container.encodeIfPresent(watchDuration, forKey: .watchDuration)
        try container.encode(isShort ? 1 : 0, forKey: .isShort)
        try container.encode(isUnavailable ? 1 : 0, forKey: .isUnavailable)
        try container.encode(isPrivate ? 1 : 0, forKey: .isPrivate)
        try container.encodeIfPresent(liveStatus, forKey: .liveStatus)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(publishedAt?.ISO8601Format(), forKey: .publishedAt)
        try container.encodeIfPresent(bucket, forKey: .bucket)
        try container.encodeIfPresent(showFrom?.ISO8601Format(), forKey: .showFrom)
        try container.encodeIfPresent(views, forKey: .views)
        try container.encodeIfPresent(channelThumbnail, forKey: .channelThumbnail)
    }

    /// "2026-11-17T09:47:40Z", with or without fractions, or SQLite's
    /// "2026-11-17 09:47:40" (UTC); a bare date counts as midday.
    static func parseTimestamp(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.count == 10 { return try? Date("\(text)T12:00:00Z", strategy: .iso8601) }
        var normalized = text.replacingOccurrences(of: " ", with: "T")
        if normalized.range(of: #"([zZ]|[+-]\d\d(:?\d\d)?)$"#, options: .regularExpression) == nil { normalized += "Z" }
        if let date = try? Date(normalized, strategy: .iso8601) { return date }
        return try? Date(normalized, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// The length on the thumbnail, as "4:05" or "1:02:03"; nil for a stream
    /// that is on now, a short, or a length the server does not know.
    var durationText: String? {
        guard liveStatus != "live", liveStatus != "upcoming", !isShort else { return nil }
        return durationSeconds.map(PlaybackTime.text)
    }

    /// "1 hr. ago", in the app's language.
    var publishedAgo: String? {
        publishedAt.map(Self.ago)
    }

    /// "1 hr. ago" for any moment, such as a channel's latest upload.
    static func ago(_ date: Date) -> String {
        let now = Date.now
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    enum LiveBadge { case live, recording }

    /// Which stream badge the card shows, if any.
    var liveBadge: LiveBadge? {
        switch liveStatus {
        case "live": .live
        case "was_live": .recording
        default: nil
        }
    }

    /// Whether the card can be played at all.
    var isPlayable: Bool {
        !isUnavailable && !isPrivate && liveStatus != "upcoming"
    }

    /// Progress from 0 to 1, when there is any.
    var progress: Double? {
        guard let watchPosition, let watchDuration, watchDuration > 0, watchPosition > 0 else { return nil }
        return min(1, watchPosition / watchDuration)
    }

    /// The length in seconds, when the server knows it.
    var durationSeconds: Double? {
        guard let duration else { return nil }
        let parts = duration.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count >= 2, !parts.contains(nil) {
            let seconds = parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
            return seconds > 0 ? Double(seconds) : nil
        }
        if let seconds = Int(duration), seconds > 0 { return Double(seconds) }
        return nil
    }

    /// Where to start: the saved position, unless it is at the very start or end.
    var resumePosition: Double {
        guard let watchPosition, let watchDuration, watchPosition > 10, watchPosition < watchDuration - 30 else { return 0 }
        return watchPosition
    }
}
