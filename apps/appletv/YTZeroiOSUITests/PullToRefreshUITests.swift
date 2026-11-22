import XCTest

/// Pulling the lists down has the server check for new videos, as Refresh
/// does, and says so. Needs a server and a session (see PlaybackUITests).
@MainActor
final class PullToRefreshUITests: XCTestCase {
    func testPullingDownRefreshes() throws {
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

        // Pull once the lists are there, at a finger's pace, holding at the end.
        XCTAssertTrue(app.staticTexts["I dag"].waitForExistence(timeout: 20), "the lists should load")
        let list = app.scrollViews.firstMatch
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: .slow, thenHoldForDuration: 0.6)

        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Opdater' OR label CONTAINS 'nye videoer'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "pulling down should refresh and say so")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "pulled"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
