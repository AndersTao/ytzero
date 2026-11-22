import XCTest

/// The Top Shelf above YT Zero on the Home Screen and the links from it.
/// Needs a server whose profile has a video in Continue watching, and YT Zero
/// in the top row of the Home Screen for the Top Shelf to show.
@MainActor
final class TopShelfUITests: XCTestCase {
    /// The first video in Continue watching, as the server lists it.
    private func firstInProgress(server: String, token: String) throws -> (id: String, title: String) {
        var request = URLRequest(url: URL(string: server)!.appending(path: "api/in-progress"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: Data?
        let done = expectation(description: "in-progress")
        URLSession.shared.dataTask(with: request) { data, _, _ in body = data; done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        let list = try JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any]
        let first = try XCTUnwrap((list?["videos"] as? [[String: Any]])?.first, "Continue watching is empty on the server")
        return (try XCTUnwrap(first["video_id"] as? String), try XCTUnwrap(first["title"] as? String))
    }

    private func launch() throws -> (XCUIApplication, (id: String, title: String)) {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"] else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER and YTZERO_UITEST_TOKEN to run against a server.")
        }
        let video = try firstInProgress(server: server, token: token)
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        app.launch()
        XCTAssertTrue(app.waitForVideoFocus(), "the home screen should load")
        return (app, video)
    }

    /// Select on a video in the Top Shelf opens YT Zero and plays it.
    func testTopShelfPlaysContinueWatching() throws {
        let (app, video) = try launch()
        let remote = XCUIRemote.shared
        // The app has saved what the Top Shelf shows; to the Home Screen.
        sleep(3)
        remote.press(.home); sleep(3)
        let board = XCUIApplication(bundleIdentifier: "com.apple.HeadBoard")
        let focused = { board.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }
        snapshot("topshelf-01-home")

        // Up from an app in the top row goes into its Top Shelf, onto the
        // item above the icon; Left from there to the video. Along the row
        // until that works, which is YT Zero.
        var found = false
        for _ in 0..<8 where !found {
            if focused().label == "YT Zero" {
                remote.press(.up); sleep(2)
                if focused().identifier == "LabeledContentTopShelfCell" {
                    for _ in 0..<8 where !focused().label.contains(video.title) {
                        remote.press(.left); sleep(1)
                    }
                    found = focused().label.contains(video.title)
                }
                if !found { remote.press(.down); sleep(2) }
            }
            if !found { remote.press(.right); sleep(3) }
        }
        guard found else {
            throw XCTSkip("YT Zero's Top Shelf did not show \(video.title): is YT Zero in the top row of the Home Screen?")
        }
        snapshot("topshelf-02-focused")
        remote.press(.select)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Select on the Top Shelf should open YT Zero")
        XCTAssertTrue(app.staticTexts[video.title].waitForExistence(timeout: 15), "YT Zero should play \(video.title)")
        sleep(2)
        snapshot("topshelf-03-playing")
    }

    /// ytzero://play?v=… plays the video, as the Top Shelf's links do.
    func testPlayLinkPlaysTheVideo() throws {
        let (app, video) = try launch()
        var link = URLComponents()
        link.scheme = "ytzero"
        link.host = "play"
        link.queryItems = [URLQueryItem(name: "v", value: video.id)]
        app.open(try XCTUnwrap(link.url))
        XCTAssertTrue(app.staticTexts[video.title].waitForExistence(timeout: 15), "the link should play \(video.title)")
        snapshot("link-01-playing")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
