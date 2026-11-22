import XCTest

/// Subscriptions from the side menu: the followed channels, searching them,
/// and a channel's videos. Needs a server and a session (see PlaybackUITests)
/// that follows channels named "Dagskanal" and "Ugekanal".
@MainActor
final class SubscriptionsUITests: XCTestCase {
    func testChannelsAndTheirVideos() throws {
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

        XCTAssertTrue(app.buttons["menu-button"].waitForExistence(timeout: 20))
        app.buttons["menu-button"].tap()
        app.buttons["Abonnementer"].tap()

        let day = app.staticTexts["Dagskanal"]
        XCTAssertTrue(day.waitForExistence(timeout: 10), "the followed channels should be listed")
        XCTAssertTrue(app.staticTexts["Ugekanal"].exists)
        snapshot("01-subscriptions")

        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "channels can be searched")
        search.tap()
        search.typeText("Uge")
        XCTAssertTrue(app.staticTexts["Ugekanal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Dagskanal"].exists, "the search should leave out other channels")

        app.staticTexts["Ugekanal"].tap()
        let video = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'timer gammel'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10), "the channel's videos should show")
        XCTAssertTrue(app.staticTexts["Video 5 timer gammel"].exists, "a video of that channel")
        XCTAssertFalse(app.staticTexts["Video 1 timer gammel"].exists, "not another channel's")
        snapshot("02-channel")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
