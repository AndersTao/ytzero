import XCTest

/// Download from a video's menu, see it arrive under Downloads, play it from
/// the device and delete it again. Needs a server and a session (see
/// PlaybackUITests), downloads turned on for the profile, and the server
/// already holding its own copy of "Video 5 timer gammel" so nothing has to
/// come from YouTube.
@MainActor
final class OfflineUITests: XCTestCase {
    func testDownloadPlayAndDelete() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"] else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER and YTZERO_UITEST_TOKEN to run against a server.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["I dag"].waitForExistence(timeout: 20), "the lists should load")

        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Video 5 timer gammel'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.press(forDuration: 1.2)
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5), "a video's menu offers Download")
        download.tap()

        app.buttons["menu-button"].tap()
        let place = app.buttons["Downloads"]
        XCTAssertTrue(place.waitForExistence(timeout: 5), "the menu has Downloads")
        place.tap()
        let row = app.buttons["download-day01xxxxxx"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the video is listed under Downloads")
        snapshot("offline-01-coming")
        let size = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' MB'")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 120), "the whole file arrives, with its size shown")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'På denne enhed'")).firstMatch.exists, "the space used is shown")
        snapshot("offline-02-ready")

        row.tap()
        sleep(6)
        snapshot("offline-03-playing")
        XCTAssertFalse(app.staticTexts["Videoen kunne ikke afspilles."].exists, "the copy on the device plays")
        app.tap()
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Luk', 'Close'}")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back on Downloads")

        row.swipeLeft()
        let delete = app.buttons["Slet"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "a swipe offers Delete")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Ingen downloads"].waitForExistence(timeout: 5), "deleted, nothing is left")
        snapshot("offline-04-deleted")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
