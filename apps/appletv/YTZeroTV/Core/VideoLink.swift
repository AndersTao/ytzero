import Foundation

/// A video someone wants to watch or save, taken from a link: the app's own
/// `ytzero://play?v=…&t=…` (the Top Shelf, the Safari extension's "Open in
/// YT Zero"), or a YouTube address shared from Safari or the YouTube app.
nonisolated struct VideoLink: Equatable, Sendable {
    let videoID: String
    /// Where to start, in seconds, when the link says.
    var start: Double?

    static let scheme = "ytzero"

    init?(videoID: String, start: Double? = nil) {
        guard Self.isVideoID(videoID) else { return nil }
        self.videoID = videoID
        self.start = start.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// `ytzero://play?v=…`, with `t` in seconds when there is a position.
    init?(appURL url: URL) {
        guard url.scheme == Self.scheme, url.host() == "play" else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let id = query.first(where: { $0.name == "v" })?.value else { return nil }
        self.init(videoID: id, start: query.first { $0.name == "t" }?.value.flatMap(Self.seconds))
    }

    /// youtube.com/watch?v=… (also m., music. and www.), youtu.be/…,
    /// /shorts/…, /live/…, /embed/…, /v/… and youtube-nocookie.com/embed/…,
    /// with the position from `t` or `start`.
    init?(youTubeURL url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let query = components.queryItems ?? []
        let path = components.path.split(separator: "/").map(String.init)
        let id: String?
        if host == "youtu.be" {
            id = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") {
            if path.first == "watch" {
                id = query.first { $0.name == "v" }?.value
            } else if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) {
                id = path[1]
            } else {
                id = nil
            }
        } else {
            id = nil
        }
        guard let id else { return nil }
        let time = query.first { $0.name == "t" || $0.name == "start" }?.value
            // youtu.be/…#t=90 and the like.
            ?? components.fragment.flatMap { fragment in fragment.hasPrefix("t=") ? String(fragment.dropFirst(2)) : nil }
        self.init(videoID: id, start: time.flatMap(Self.seconds))
    }

    /// The first YouTube link in what was shared: the YouTube app shares the
    /// link alone, some apps the title with the link after it.
    init?(text: String) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, let link = VideoLink(youTubeURL: url) {
                self = link
                return
            }
        }
        return nil
    }

    /// The link that opens the app and plays the video there.
    var appURL: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        if let start { components.queryItems?.append(URLQueryItem(name: "t", value: String(Int(start)))) }
        return components.url
    }

    /// What the server accepts as a video id.
    static func isVideoID(_ text: String) -> Bool {
        (6...20).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// "90", "90s", "1m30s" or "1h2m3s" in seconds.
    static func seconds(_ text: String) -> Double? {
        if let plain = Double(text) { return plain }
        var total = 0.0
        var number = ""
        for character in text.lowercased() {
            if character.isNumber {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            number = ""
        }
        guard number.isEmpty else { return nil }
        return total
    }
}
