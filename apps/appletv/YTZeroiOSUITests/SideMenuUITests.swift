import XCTest

/// The side menu: a swipe from the left edge opens it with the main places
/// and the profile's playlists, a choice closes it, and the menu button opens
/// it again. Needs a server and a session (see PlaybackUITests).
@MainActor
final class SideMenuUITests: XCTestCase {
    func testSwipeOpensTheMenu() throws {
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

        // From the very left edge towards the middle.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        let scheduled = app.buttons["Planlagt"]
        XCTAssertTrue(scheduled.waitForExistence(timeout: 5), "a swipe from the edge should open the menu")
        for place in ["Main", "Anbefalinger", "Shorts", "Abonnementer"] {
            XCTAssertTrue(app.buttons[place].exists, "the menu should have \(place)")
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Mine playlister'")).firstMatch.exists, "the menu should have My playlists")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Se senere'")).firstMatch.exists, "the menu should list the playlists")
        snapshot("01-menu")

        scheduled.tap()
        XCTAssertTrue(app.staticTexts["Kommer snart"].waitForExistence(timeout: 5), "Scheduled has no screen yet")
        XCTAssertFalse(app.buttons["Abonnementer"].exists, "choosing closes the menu")

        app.buttons["menu-button"].tap()
        XCTAssertTrue(app.buttons["Main"].waitForExistence(timeout: 5), "the menu button opens it too")
        app.buttons["Main"].tap()
        XCTAssertTrue(app.staticTexts["I dag"].waitForExistence(timeout: 10), "Main is the lists again")
        snapshot("02-main")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
