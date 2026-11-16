import Foundation

/// A video as the YT Zero API returns it, reduced to what this app shows.
nonisolated struct Video: Decodable, Identifiable, Hashable, Sendable {
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

    /// Where to start: the saved position, unless it is at the very start or end.
    var resumePosition: Double {
        guard let watchPosition, let watchDuration, watchPosition > 10, watchPosition < watchDuration - 30 else { return 0 }
        return watchPosition
    }
}
