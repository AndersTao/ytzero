import XCTest

/// Opens the first video on the Continue watching shelf in the system player,
/// lets it play and closes it again, keeping a screenshot of each step. Needs
/// a running server and a device session for it, as the Apple TV app's
/// RemoteFlowUITests do.
@MainActor
final class PlaybackUITests: XCTestCase {
    func testPlayFromContinueWatching() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"] else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER and YTZERO_UITEST_TOKEN to run against a server.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Fortsæt med at se"].waitForExistence(timeout: 15), "the shelf should load")
        snapshot("01-home")
        // The shelf is the scroll view inside the page's own.
        let shelf = app.scrollViews.element(boundBy: 1)
        XCTAssertTrue(shelf.buttons.firstMatch.waitForExistence(timeout: 5), "the shelf should have a video")
        shelf.buttons.firstMatch.tap()

        // Time to fetch, start the stream and play a little.
        sleep(20)
        snapshot("02-playing")
        XCTAssertFalse(app.staticTexts["Videoen kunne ikke afspilles."].exists, "the video should play")
        app.tap()
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Luk', 'Close', 'Færdig', 'Done'}")).firstMatch
        _ = close.waitForExistence(timeout: 3)
        snapshot("03-controls")
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.staticTexts["Fortsæt med at se"].waitForExistence(timeout: 10), "closing should return to the shelves")
        snapshot("04-back-home")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
