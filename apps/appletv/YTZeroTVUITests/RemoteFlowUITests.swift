import XCTest

/// Walks the main flow with the Siri Remote and keeps a screenshot of each
/// step as a test attachment. Needs a running server the app is paired with.
@MainActor
final class RemoteFlowUITests: XCTestCase {
    func testRemoteFlow() throws {
        // Set TEST_RUNNER_YTZERO_UITEST_SERVER and TEST_RUNNER_YTZERO_UITEST_TOKEN
        // (a device session for that server) when running the test.
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"] else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER and YTZERO_UITEST_TOKEN to run against a server.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        app.launch()
        let remote = XCUIRemote.shared

        sleep(6)
        snapshot("01-home")
        // Up from the first video reaches the header (Refresh / Settings).
        remote.press(.up)
        sleep(1)
        let refresh = app.buttons["Opdater"]
        let settings = app.buttons["Indstillinger"]
        XCTAssertTrue(refresh.hasFocus || settings.hasFocus, "Up from the first video should reach the header")
        snapshot("01b-header")
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        snapshot("02-first-card-focused")
        remote.press(.select, forDuration: 1.5)
        sleep(2)
        snapshot("03-long-press-menu")
        remote.press(.menu)
        sleep(1)
        remote.press(.select)
        // Long enough for a refused direct stream to fall back to the relay.
        sleep(25)
        snapshot("04-player")
        remote.press(.right)
        sleep(1)
        snapshot("05-seek-forward")
        remote.press(.playPause)
        sleep(1)
        snapshot("06-paused")
        remote.press(.menu)
        sleep(3)
        snapshot("07-back-home")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
