import XCTest

/// Plays for over a minute while the server is restarted from outside, which
/// drops every media ticket. Run by hand: it needs someone to restart the
/// server during the wait (YTZERO_UITEST_RESTART=1).
@MainActor
final class RecoveryUITests: XCTestCase {
    func testKeepsPlayingAfterTheTicketIsGone() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YTZERO_UITEST_RESTART"] == "1", let server = env["YTZERO_UITEST_SERVER"], let token = env["YTZERO_UITEST_TOKEN"] else {
            throw XCTSkip("Needs a server that gets restarted during the test.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let shelf = app.scrollViews.element(boundBy: 1)
        XCTAssertTrue(shelf.buttons.firstMatch.waitForExistence(timeout: 15))
        shelf.buttons.firstMatch.tap()
        sleep(12)
        let start = shownPosition(app)
        print("RECOVERY start", start)
        sleep(170)
        let end = shownPosition(app)
        print("RECOVERY end", end)
        XCTAssertFalse(app.staticTexts["Videoen kunne ikke afspilles."].exists, "playback should not fail")
        XCTAssertGreaterThan(end - start, 140, "it should have kept playing through the restart")
    }

    private func shownPosition(_ app: XCUIApplication) -> Int {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}(:[0-9]{2})?$'")).firstMatch
        _ = clock.waitForExistence(timeout: 3)
        let seconds = clock.label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        return seconds
    }
}
