import Foundation

/// What the Top Shelf shows above YT Zero on the Apple TV's Home Screen.
///
/// The app writes it, with a picture file per video, into the container of
/// the App Group the two share; the Top Shelf extension only reads it. So the
/// extension needs neither the server's address nor a session: the pictures
/// come through the server's image proxy, which wants the session's token.
/// The App Group comes from the build settings (YTZERO_APP_GROUP), through
/// the YTZeroAppGroup key in both Info.plists.
nonisolated struct TopShelfSnapshot: Codable, Sendable {
    struct Section: Codable, Sendable {
        var title: String
        var items: [Item]
    }

    struct Item: Codable, Sendable {
        var id: String
        var title: String
        var channel: String
        /// 0 to 1, for the bar under the picture; nil when not started.
        var progress: Double?
        /// The picture's file name in `directory`.
        var image: String?
    }

    var sections: [Section]

    /// Where the snapshot and its pictures live; nil without an App Group.
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "YTZeroAppGroup") as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appending(path: "TopShelf", directoryHint: .isDirectory)
    }

    static func load() -> TopShelfSnapshot? {
        guard let file = directory?.appending(path: "snapshot.json"), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    func save() throws {
        guard let directory = Self.directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appending(path: "snapshot.json"), options: .atomic)
    }

    // MARK: Links back into the app

    static let scheme = "ytzero"

    /// Opens the app and plays the video, from where it was left.
    static func playURL(for videoID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    /// The video a link from the Top Shelf asks to play.
    static func videoID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "play",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
              !id.isEmpty else { return nil }
        return id
    }
}
