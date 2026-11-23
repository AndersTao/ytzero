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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Planlagt til i aften'")).firstMatch.waitForExistence(timeout: 10), "Scheduled lists what is scheduled")
        XCTAssertFalse(app.buttons["Abonnementer"].exists, "choosing closes the menu")

        app.buttons["menu-button"].tap()
        XCTAssertTrue(app.buttons["Main"].waitForExistence(timeout: 5), "the menu button opens it too")
        app.buttons["Main"].tap()
        XCTAssertTrue(app.staticTexts["I dag"].waitForExistence(timeout: 10), "Main is the lists again")
        snapshot("02-main")
    }

    /// A playlist from the menu lists all its videos in Main's grid, without
    /// the days, and who is watching sits at the bottom of the menu and opens
    /// Settings.
    func testPlaylistAndProfile() throws {
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
        XCTAssertFalse(app.buttons["profile-button"].exists, "the profile is no longer in the bar")

        app.buttons["menu-button"].tap()
        let playlist = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Se senere'")).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile-button"].exists, "who is watching is at the bottom of the menu")
        snapshot("03-menu-profile")
        playlist.tap()

        let videos = app.buttons.matching(NSPredicate(format: "label CONTAINS 'timer gammel'"))
        XCTAssertTrue(videos.firstMatch.waitForExistence(timeout: 10), "the playlist's videos should load")
        XCTAssertGreaterThanOrEqual(videos.count, 3, "every video on the list is shown")
        XCTAssertFalse(app.staticTexts["I dag"].exists, "a playlist has no days")
        snapshot("04-playlist")

        app.buttons["menu-button"].tap()
        app.buttons["profile-button"].tap()
        XCTAssertTrue(app.staticTexts["Hvem ser med?"].waitForExistence(timeout: 5), "the profile opens Settings")
        XCTAssertTrue(app.buttons["Log ud"].exists)
        XCTAssertTrue(app.buttons["Brug en anden server"].exists)
        snapshot("05-settings")
    }

    /// Shorts and Scheduled are cut into headings as Main is (Scheduled by
    /// when, as on the web); Recommendations is one grid, or says why it is
    /// empty. Needs the dev data's two Shorts and two scheduled videos.
    func testListsFromTheMenu() throws {
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
        let heading = { (title: String) in app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch }

        app.buttons["menu-button"].tap()
        app.buttons["Shorts"].tap()
        let short = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Short 2 timer gammel'")).firstMatch
        XCTAssertTrue(short.waitForExistence(timeout: 10), "Shorts lists the Shorts")
        XCTAssertTrue(heading("I dag").exists, "Shorts has days like Main")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Video 1 timer gammel'")).firstMatch.exists, "only Shorts")
        snapshot("06-shorts")

        app.buttons["menu-button"].tap()
        app.buttons["Planlagt"].tap()
        let tonight = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Planlagt til i aften'")).firstMatch
        XCTAssertTrue(tonight.waitForExistence(timeout: 10), "Scheduled lists what is scheduled")
        XCTAssertTrue(heading("I dag").exists, "tonight is under Today")
        XCTAssertTrue(heading("I morgen").exists, "tomorrow has its own heading")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Short 2 timer gammel'")).firstMatch.exists)
        snapshot("07-scheduled")
        tonight.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Fjern fra Planlagt"].waitForExistence(timeout: 5), "a scheduled video can be taken off")
        XCTAssertFalse(app.buttons["Afvis"].exists, "not rejected from here")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        XCTAssertTrue(app.buttons["Fjern fra Planlagt"].waitForNonExistence(timeout: 5), "the menu of the card closes")

        app.buttons["menu-button"].tap()
        XCTAssertTrue(app.buttons["Anbefalinger"].waitForExistence(timeout: 5))
        app.buttons["Anbefalinger"].tap()
        let answered = app.staticTexts.matching(NSPredicate(format: "label IN {'Anbefalinger er slået fra', 'Ingen anbefalinger endnu'}")).firstMatch
        let anyVideo = app.buttons.matching(NSPredicate(format: "label CONTAINS 'gammel'")).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 10) || anyVideo.exists, "Recommendations lists videos or says why not")
        XCTAssertFalse(app.staticTexts["Kommer snart"].exists)
        snapshot("08-recommendations")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
