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

        app.waitForVideoFocus()
        snapshot("01-home")
        // Up from the first video reaches the header (Refresh / profile picture).
        remote.press(.up)
        sleep(1)
        let refresh = app.buttons["Opdater"]
        let settings = app.buttons["profile-button"]
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

    /// The header buttons sit at the right edge, above where a short row has
    /// no card: Down from either of them, also while a refresh is running,
    /// has to land on a video rather than stay in the header.
    func testDownLeavesTheHeader() throws {
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
        let refresh = app.buttons["Opdater"]
        let settings = app.buttons["profile-button"]
        let focused = { app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }
        // While a refresh runs the button is "Opdaterer…" and "Opdater" is not
        // there at all: asking it for focus then fails the test instead of answering.
        let onHeader = { (refresh.exists && refresh.hasFocus) || settings.hasFocus || focused().label.hasPrefix("Opdaterer") }
        app.waitForVideoFocus()

        // One Up: a second one goes on to the sidebar.
        remote.press(.up); sleep(1)
        XCTAssertTrue(refresh.hasFocus, "Up should reach Refresh")
        remote.press(.down); sleep(1)
        XCTAssertFalse(onHeader(), "Down from Refresh should reach a video, focus is on \(focused().label)")

        remote.press(.up); sleep(1)
        remote.press(.right); sleep(1)
        XCTAssertTrue(settings.hasFocus, "Right from Refresh should reach the profile picture")
        remote.press(.down); sleep(1)
        XCTAssertFalse(onHeader(), "Down from Settings should reach a video, focus is on \(focused().label)")

        remote.press(.up); sleep(1)
        remote.press(.left); sleep(1)
        remote.press(.select); sleep(1)
        snapshot("refreshing")
        remote.press(.down); sleep(1)
        XCTAssertFalse(onHeader(), "Down while refreshing should reach a video, focus is on \(focused().label)")
    }

    /// The app starts on Main with the sidebar folded away to a button at
    /// the top left. Up from the header opens it; the places still to come
    /// say so, and a playlist in "My playlists" shows its videos. Needs a
    /// profile with a playlist named "Weekend" that has a video in it.
    func testSidebarOpensAPlaylist() throws {
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
        let focused = { app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }

        // A sidebar row is a cell whose name is in a text inside it.
        let place = { focused().elementType == .cell ? focused().staticTexts.firstMatch.label : "" }
        XCTAssertTrue(app.waitForVideoFocus(), "the remote should end up on a video with the sidebar folded away")
        snapshot("sidebar-01-folded")

        remote.press(.up); sleep(1)
        XCTAssertTrue(app.buttons["Opdater"].hasFocus, "Up from the first video should reach Refresh")
        remote.press(.up); sleep(2)
        XCTAssertEqual(place(), "Main", "Up from the header should open the sidebar on Main")
        snapshot("sidebar-02-open")

        // Down to the first playlist; Select shows its videos and folds the sidebar.
        for _ in 0..<8 where place() != "Weekend" {
            remote.press(.down); sleep(1)
        }
        XCTAssertEqual(place(), "Weekend", "Down should reach the first playlist")
        remote.press(.select)
        XCTAssertTrue(app.waitForVideoFocus(), "a video of the playlist should have the focus")
        snapshot("sidebar-03-playlist")

        // Up from the playlist's top row opens the sidebar again; a place
        // still to come says so.
        remote.press(.up); sleep(2)
        for _ in 0..<8 where place() != "Anbefalinger" {
            remote.press(.up); sleep(1)
        }
        XCTAssertEqual(place(), "Anbefalinger", "Up should reach Recommendations")
        remote.press(.select); sleep(2)
        XCTAssertTrue(app.staticTexts["Kommer snart"].waitForExistence(timeout: 5), "Recommendations should say it is coming soon")
        snapshot("sidebar-04-coming-soon")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIApplication {
    /// At launch the sidebar shows for a moment and then folds away by
    /// itself, leaving the focus on the first video. True once it has.
    @discardableResult
    func waitForVideoFocus(timeout: Int = 20) -> Bool {
        let focused = { self.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }
        for _ in 0..<timeout {
            let element = focused()
            // A card, below the header; a sidebar row is a cell.
            if element.exists && element.elementType == .button && element.frame.minY > 250 {
                return true
            }
            sleep(1)
        }
        return false
    }
}
