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
    func exchange(deviceCode: String) async throws -> String {
        let (data, response) = try await send(request("/auth/device/token", method: "POST", body: ["device_code": deviceCode]))
        switch response.statusCode {
        case 428: throw APIError.pending
        case 400: throw APIError.expired
        default: return try decode(APIModels.DeviceToken.self, from: data, status: response.statusCode).accessToken
        }
    }

    func isAuthenticated() async throws -> Bool {
        let (data, response) = try await send(request("/auth/status"))
        return try decode(APIModels.AuthStatus.self, from: data, status: response.statusCode).authenticated
    }

    // MARK: Library

    func feed(page: Int) async throws -> [Video] {
        let (data, response) = try await send(request("/feed", query: [URLQueryItem(name: "page", value: String(page))]))
        return try decode(APIModels.VideoList.self, from: data, status: response.statusCode).videos
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

    func releaseTicket(_ id: String, ticket: String) async {
        _ = try? await send(request("/videos/\(id)/playback-ticket", method: "DELETE", body: ["ticket": ticket]))
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
