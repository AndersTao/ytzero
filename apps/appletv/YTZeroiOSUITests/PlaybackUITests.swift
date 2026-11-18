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
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        XCTAssertTrue(app.staticTexts["Fortsæt med at se"].waitForExistence(timeout: 15), "the shelf should load")
        snapshot("01-home")
        // The shelf is the scroll view inside the page's own.
        let shelf = app.scrollViews.element(boundBy: 1)
        XCTAssertTrue(shelf.buttons.firstMatch.waitForExistence(timeout: 5), "the shelf should have a video")
        let watchedBefore = shelf.buttons.firstMatch.value as? String ?? ""
        shelf.buttons.firstMatch.tap()

        sleep(1)
        snapshot("02-preparing")
        // Time to fetch, start the stream and play a little. AVKit's controls
        // should have hidden themselves by then, without a tap.
        sleep(15)
        snapshot("02-playing")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label IN {'Luk', 'Close'}")).firstMatch.isHittable,
                       "the player's controls should hide on their own once it plays")
        XCTAssertFalse(app.staticTexts["Videoen kunne ikke afspilles."].exists, "the video should play")

        let picture: XCUIElement = app  // not windows.firstMatch: on iPad that is a 0×0 window once the player is up
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        if isPhone {
            // Standing up, a double tap on the side does nothing on an iPhone.
            let start = shownPosition(app, picture)
            picture.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).doubleTap()
            sleep(4)
            let moved = shownPosition(app, picture) - start
            XCTAssertTrue((0...10).contains(moved), "no side skip while upright (moved \(moved) s)")
            // Sideways, it skips 15 s on the side tapped, with the controls away.
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
        }
        let before = shownPosition(app, picture)
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).doubleTap()
        snapshot("02-skip-forward")
        let forward = shownPosition(app, picture) - before
        XCTAssertTrue((13...26).contains(forward), "a double tap on the right skips 15 s forward (moved \(forward) s)")
        let middle = shownPosition(app, picture)
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).doubleTap()
        let back = shownPosition(app, picture) - middle
        XCTAssertTrue((-17 ... -5).contains(back), "a double tap on the left skips 15 s back (moved \(back) s)")
        if isPhone {
            XCUIDevice.shared.orientation = .portrait
            sleep(1)
        }

        app.tap()
        XCTAssertTrue(app.buttons["30 sekunder frem"].waitForExistence(timeout: 3), "the forward button skips 30 s")
        XCTAssertTrue(app.buttons["15 sekunder tilbage"].exists, "the back button skips 15 s")
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Luk', 'Close', 'Færdig', 'Done'}")).firstMatch
        _ = close.waitForExistence(timeout: 3)
        snapshot("03-controls")
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.staticTexts["Fortsæt med at se"].waitForExistence(timeout: 10), "closing should return to the shelves")
        snapshot("04-back-home")
        // How far it got shows straight away, without refreshing.
        let moved = NSPredicate { _, _ in (shelf.buttons.firstMatch.value as? String ?? "") != watchedBefore }
        let progressShown = XCTNSPredicateExpectation(predicate: moved, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [progressShown], timeout: 5), .completed,
                       "the card should show the new position (was \(watchedBefore))")
        snapshot("05-progress")
    }

    /// The elapsed time the controls show, in seconds. Brings them up with a
    /// tap in the middle and sends them away again.
    private func shownPosition(_ app: XCUIApplication, _ picture: XCUIElement) -> Int {
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}(:[0-9]{2})?$'")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 3), "the controls should show the time")
        let seconds = clock.label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = clock.waitForNonExistence(timeout: 3)
        return seconds
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
