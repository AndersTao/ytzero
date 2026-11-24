import Foundation

/// Talks to one YT Zero instance with this Apple TV's device session.
///
/// The session comes from the instance's own TV pairing (a code approved on a
/// phone), and is sent as a bearer token. Nothing about a particular instance
/// is built in: the address is whatever was entered on first launch.
nonisolated struct APIClient: Sendable {
    let baseURL: URL
    var token: String?

    private static let decoder = JSONDecoder()

    // MARK: Requests

    private func url(_ path: String) -> URL {
        baseURL.appending(path: "api").appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: (any Encodable & Sendable)? = nil) throws -> URLRequest {
        var components = URLComponents(url: url(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let target = components?.url else { throw APIError.invalidAddress }
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.server(status: 0, message: nil) }
        if http.statusCode == 401 { throw APIError.unauthorized }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
        guard (200..<300).contains(status) else { throw APIError.server(status: status, message: Self.errorMessage(data)) }
        return try Self.decoder.decode(T.self, from: data)
    }

    private func expectSuccess(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(status: response.statusCode, message: Self.errorMessage(data))
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    // MARK: Server

    /// Whether the address answers as a YT Zero server.
    func checkHealth() async throws {
        let (data, response) = try await send(request("/health"))
        let app = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["app"] as? String
        guard response.statusCode == 200, app == "ytzero" else { throw APIError.server(status: response.statusCode, message: nil) }
    }

    // MARK: Pairing

    /// `deviceName` is how the server lists this device among the signed-in ones.
    func beginPairing(deviceName: String) async throws -> APIModels.DeviceCode {
        let (data, response) = try await send(request("/auth/device/code", method: "POST", body: ["device_name": deviceName]))
        return try decode(APIModels.DeviceCode.self, from: data, status: response.statusCode)
    }

    /// The session token once the code is approved; `.pending` until then.
    /// `link` adds a profile: the new session joins the one this client has,
    /// so the server lets this device move between them.
    func exchange(deviceCode: String, link: Bool = false) async throws -> String {
        struct Body: Encodable, Sendable {
            let deviceCode: String
            let linkSession: Bool?

            enum CodingKeys: String, CodingKey {
                case deviceCode = "device_code"
                case linkSession = "link_session"
            }
        }
        let body = Body(deviceCode: deviceCode, linkSession: link ? true : nil)
        let (data, response) = try await send(request("/auth/device/token", method: "POST", body: body))
        switch response.statusCode {
        case 428: throw APIError.pending
        case 400: throw APIError.expired
        default: return try decode(APIModels.DeviceToken.self, from: data, status: response.statusCode).accessToken
        }
    }

    func authStatus() async throws -> APIModels.AuthStatus {
        let (data, response) = try await send(request("/auth/status"))
        return try decode(APIModels.AuthStatus.self, from: data, status: response.statusCode)
    }

    func isAuthenticated() async throws -> Bool {
        try await authStatus().authenticated
    }

    /// Ends this client's session on the server.
    func signOut() async {
        _ = try? await send(request("/auth/logout", method: "POST", body: [String: String]()))
    }

    // MARK: Profiles

    /// The profiles paired on this device (each with a session of its own),
    /// and which one this session is.
    func deviceProfiles() async throws -> APIModels.ProfileList {
        let (data, response) = try await send(request("/auth/device/profiles"))
        return try decode(APIModels.ProfileList.self, from: data, status: response.statusCode)
    }

    /// Asks the server whether this device may move to another of its paired
    /// profiles; the switch itself is using that profile's session.
    func switchDeviceProfile(to id: Int, childLockPin: String?) async throws -> APIModels.SwitchResult {
        struct Body: Encodable, Sendable {
            let id: Int
            let childLockPin: String?

            enum CodingKeys: String, CodingKey {
                case id
                case childLockPin = "child_lock_pin"
            }
        }
        return try await switchResult(request("/auth/device/profiles/switch", method: "POST", body: Body(id: id, childLockPin: childLockPin)))
    }

    /// Signs the profile out on this device, on the server too.
    func removeDeviceProfile(_ id: Int) async throws {
        let (data, response) = try await send(request("/auth/device/profiles/\(id)", method: "DELETE"))
        if response.statusCode == 404 { return }
        try expectSuccess(data, response)
    }

    /// Every profile, where this session may switch between them by itself.
    func profiles() async throws -> APIModels.ProfileList {
        let (data, response) = try await send(request("/profiles"))
        return try decode(APIModels.ProfileList.self, from: data, status: response.statusCode)
    }

    /// Switches this session itself to another profile.
    func switchProfile(to id: Int, childLockPin: String?, pin: String?) async throws -> APIModels.SwitchResult {
        struct Body: Encodable, Sendable {
            let id: Int
            let childLockPin: String?
            let pin: String?

            enum CodingKeys: String, CodingKey {
                case id, pin
                case childLockPin = "child_lock_pin"
            }
        }
        return try await switchResult(request("/profiles/switch", method: "POST", body: Body(id: id, childLockPin: childLockPin, pin: pin)))
    }

    /// Both switches answer alike. A 401 here is the PIN, not the session.
    private func switchResult(_ request: URLRequest) async throws -> APIModels.SwitchResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        switch status {
        case 200..<300 where body["requires_relogin"] as? Bool != true: return .switched
        case 401 where body["pin_locked"] as? Bool == true: return .locked
        case 401 where body["pin_required"] as? Bool == true: return .needsPin
        case 401 where body["error"] as? String == "invalid PIN": return .wrongPin
        case 401: throw APIError.unauthorized
        case 404: return .notPaired
        default: throw APIError.server(status: status, message: body["error"] as? String)
        }
    }

    /// A profile picture: `path` is the server's own, with its version query.
    func avatarData(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw APIError.invalidAddress }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await send(request)
        try expectSuccess(data, response)
        return data
    }

    // MARK: Library

    func feed(page: Int) async throws -> [Video] {
        let (data, response) = try await send(request("/feed", query: [URLQueryItem(name: "page", value: String(page))]))
        return try decode(APIModels.VideoList.self, from: data, status: response.statusCode).videos
    }

    /// The channels this profile follows.
    func channels() async throws -> [APIModels.Channel] {
        let (data, response) = try await send(request("/channels"))
        return try decode(APIModels.ChannelList.self, from: data, status: response.statusCode).channels.filter { $0.followed != 0 }
    }

    /// One channel's videos, newest first, watched or not, as its page on the web shows them.
    func channelVideos(_ channelID: String, page: Int) async throws -> [Video] {
        let (data, response) = try await send(request("/feed", query: [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "status", value: "all"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: "40"),
        ]))
        return try decode(APIModels.VideoList.self, from: data, status: response.statusCode).videos
    }

    /// The profile's own playlists, in the order the web client shows them.
    func playlists() async throws -> [APIModels.UserPlaylist] {
        let (data, response) = try await send(request("/playlists"))
        return try decode(APIModels.UserPlaylists.self, from: data, status: response.statusCode).playlists
    }

    /// The videos of one of the profile's playlists, the last added first.
    func playlistVideos(_ id: Int) async throws -> [Video] {
        let (data, response) = try await send(request("/playlists/\(id)", query: [URLQueryItem(name: "sort", value: "added-newest")]))
        return try decode(APIModels.VideoList.self, from: data, status: response.statusCode).videos
    }

    /// The Shorts feed: the same inbox as Main, Shorts only, newest first.
    func shorts(page: Int) async throws -> [Video] {
        let (data, response) = try await send(request("/feed", query: [
            URLQueryItem(name: "only_shorts", value: "1"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: "40"),
        ]))
        return try decode(APIModels.VideoList.self, from: data, status: response.statusCode).videos
    }

    /// What the profile has scheduled to watch ("Scheduled" on the web).
    func watchlist() async throws -> [Video] {
        let (data, response) = try await send(request("/watchlist"))
        return try decode(APIModels.VideoList.self, from: data, status: response.statusCode).videos
    }

    /// One page of the server's recommendations, best first. `refresh` on the
    /// first page has the server work them out again.
    func recommendations(page: Int, refresh: Bool = false) async throws -> APIModels.Recommendations {
        var query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "40")]
        if refresh { query.append(URLQueryItem(name: "refresh", value: "1")) }
        let (data, response) = try await send(request("/recommendations", query: query))
        return try decode(APIModels.Recommendations.self, from: data, status: response.statusCode)
    }

    /// Schedules a video, or moves it to another time: "today", "tonight",
    /// "tomorrow", "tomorrow_evening" or "weekend".
    func schedule(_ id: String, bucket: String) async throws {
        let (data, response) = try await send(request("/videos/\(id)/queue", method: "POST", body: ["bucket": bucket]))
        try expectSuccess(data, response)
    }

    /// Takes a video off Scheduled, back to the feed.
    func unschedule(_ id: String) async throws {
        let (data, response) = try await send(request("/videos/\(id)/dequeue", method: "POST"))
        try expectSuccess(data, response)
    }

    func inProgress() async throws -> [Video] {
        let (data, response) = try await send(request("/in-progress"))
        return try decode(APIModels.VideoList.self, from: data, status: response.statusCode).videos
    }

    /// Ask the server to check subscriptions for new uploads now.
    func refreshSubscriptions() async throws -> Int {
        var refresh = try request("/refresh", method: "POST", body: [String: String]())
        refresh.timeoutInterval = 120
        let (data, response) = try await send(refresh)
        return try decode(APIModels.RefreshResult.self, from: data, status: response.statusCode).added
    }

    func markWatched(_ id: String) async throws {
        let (data, response) = try await send(request("/videos/\(id)/complete", method: "POST", body: [String: String]()))
        try expectSuccess(data, response)
    }

    func reject(_ id: String) async throws {
        let (data, response) = try await send(request("/videos/\(id)/archive", method: "POST", body: [String: String]()))
        try expectSuccess(data, response)
    }

    /// Records the visit that puts a video on the Continue watching shelf.
    func recordVisit(_ id: String) async throws {
        let (data, response) = try await send(request("/videos/\(id)/watch", method: "POST", body: [String: String]()))
        try expectSuccess(data, response)
    }

    func saveProgress(_ id: String, position: Double, duration: Double) async throws {
        struct Body: Encodable, Sendable { let position: Double; let duration: Double }
        let (data, response) = try await send(request("/videos/\(id)/progress", method: "PUT", body: Body(position: position, duration: duration)))
        try expectSuccess(data, response)
    }

    // MARK: Playback

    /// A playable stream for the video; `.pending` while the server prepares it.
    /// Fetched by the server with yt-dlp and served as it arrives:
    /// "relay-hls" as separate full-quality tracks in one HLS presentation,
    /// "relay" as YouTube's one muxed file (360p). No source lets the server
    /// choose, which is how a stream that is live now is played. `start` is
    /// where playback will begin, so the server can be ready there.
    func playbackTicket(_ id: String, source: String?, start: Double) async throws -> (ticket: String, url: URL, expiresIn: Double) {
        struct Body: Encodable, Sendable { let source: String?; let start: Double }
        let (data, response) = try await send(request("/videos/\(id)/playback-ticket", method: "POST", body: Body(source: source, start: start)))
        if response.statusCode == 202 { throw APIError.pending }
        let ticket = try decode(APIModels.PlaybackTicket.self, from: data, status: response.statusCode)
        // The server answers with a path on itself; the media requests carry the
        // ticket in their URL, because a player sends no Authorization header.
        guard let streamURL = URL(string: ticket.url, relativeTo: baseURL)?.absoluteURL else { throw APIError.invalidAddress }
        return (ticket.ticket, streamURL, ticket.expiresIn)
    }

    func renewTicket(_ id: String, ticket: String) async throws {
        let (data, response) = try await send(request("/videos/\(id)/playback-ticket", method: "PUT", body: ["ticket": ticket]))
        try expectSuccess(data, response)
    }

    /// Let a stream's ticket go. `reason`, when the player gave up on the
    /// stream, ends up in the server's log.
    func releaseTicket(_ id: String, ticket: String, reason: String? = nil) async {
        var body = ["ticket": ticket]
        if let reason { body["reason"] = reason }
        _ = try? await send(request("/videos/\(id)/playback-ticket", method: "DELETE", body: body))
    }

    // MARK: Offline

    /// A copy of the video for this device to keep: the H.264 and AAC the
    /// apps stream, no higher than `height` (480, 720 or 1080), in one MP4. While the server fetches them it answers with
    /// how far it is; then with the file's address, a ticket in it.
    func offlineCopy(_ id: String, height: Int) async throws -> APIModels.OfflineCopy {
        struct Body: Encodable, Sendable { let source: String; let height: Int }
        let (data, response) = try await send(request("/videos/\(id)/playback-ticket", method: "POST", body: Body(source: "offline", height: height)))
        if response.statusCode == 202 {
            let progress = (try? Self.decoder.decode(APIModels.Preparing.self, from: data))?.progress
            return .preparing(progress: progress)
        }
        let ticket = try decode(APIModels.PlaybackTicket.self, from: data, status: response.statusCode)
        guard let url = URL(string: ticket.url, relativeTo: baseURL)?.absoluteURL else { throw APIError.invalidAddress }
        // A server from before offline copies answers with a stream instead,
        // which is no file to keep.
        guard url.path().hasSuffix("/offline.mp4") else {
            throw APIError.server(status: 501, message: String(localized: "The server is too old for offline copies."))
        }
        return .ready(url)
    }

    // MARK: Images

    /// Thumbnails go through the server's image proxy, which needs the session too.
    func imageData(for thumbnail: String) async throws -> Data {
        let path: String
        let query: [URLQueryItem]
        if thumbnail.hasPrefix("http://") || thumbnail.hasPrefix("https://") {
            path = "/img"
            query = [URLQueryItem(name: "u", value: thumbnail)]
        } else {
            path = thumbnail.replacing("/api/", with: "/", maxReplacements: 1)
            query = []
        }
        let (data, response) = try await send(request(path, query: query))
        try expectSuccess(data, response)
        return data
    }
}
