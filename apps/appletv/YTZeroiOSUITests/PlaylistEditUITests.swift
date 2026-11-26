import XCTest

/// Touch and hold on a video in a playlist takes it out of the playlist: the
/// card goes at once and the server no longer lists it. The test makes a
/// playlist of its own with two of the dev data's videos and deletes it after.
final class PlaylistEditUITests: XCTestCase {
    private var server = ""
    private var token = ""
    private var playlistID: Int?
    private let playlistName = "UI test removal"

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"] else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER and YTZERO_UITEST_TOKEN to run against a server.")
        }
        self.server = server
        self.token = token
        continueAfterFailure = false
        let created = try call("POST", "/playlists", body: ["name": playlistName])
        let playlist = try XCTUnwrap(created["playlist"] as? [String: Any])
        let id = try XCTUnwrap(playlist["id"] as? Int)
        playlistID = id
        for video in ["jNQXAC9IVRw", "dQw4w9WgXcQ"] {
            _ = try call("POST", "/playlists/\(id)/videos", body: ["video_id": video])
        }
    }

    override func tearDownWithError() throws {
        if let playlistID { _ = try? call("DELETE", "/playlists/\(playlistID)") }
    }

    func testTouchAndHoldRemovesAVideoFromThePlaylist() throws {
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["menu-button"].waitForExistence(timeout: 20))

        app.buttons["menu-button"].tap()
        let playlist = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", playlistName)).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5), "the menu should list the test playlist")
        playlist.tap()

        let zoo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Me at the zoo'")).firstMatch
        XCTAssertTrue(zoo.waitForExistence(timeout: 10), "the playlist's videos should load")
        zoo.press(forDuration: 1.2)
        let remove = app.buttons["Fjern fra playlisten"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "touch and hold should offer to remove it")
        snapshot("06-playlist-remove")
        remove.tap()

        XCTAssertTrue(zoo.waitForNonExistence(timeout: 5), "the card should go at once")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rick Astley'")).firstMatch.exists, "the other video stays")
        let remaining = try serverVideoIDs()
        XCTAssertEqual(remaining, ["dQw4w9WgXcQ"], "the server should no longer list it")
    }

    private func serverVideoIDs() throws -> [String] {
        let id = try XCTUnwrap(playlistID)
        // The removal is sent as the card goes; give it a moment.
        for _ in 0..<10 {
            let videos = try call("GET", "/playlists/\(id)")["videos"] as? [[String: Any]] ?? []
            let ids = videos.compactMap { $0["video_id"] as? String }
            if ids.count < 2 { return ids }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return []
    }

    @discardableResult
    private func call(_ method: String, _ path: String, body: [String: String]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + "/api" + path)))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        let done = expectation(description: "\(method) \(path)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                result = .failure(URLError(.badServerResponse, userInfo: ["status": status]))
            } else {
                result = .success(data ?? Data())
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        let data = try result.get()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
