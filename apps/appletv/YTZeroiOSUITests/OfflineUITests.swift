import XCTest

/// Download from a video's menu, see it arrive under Downloads, play it from
/// the device and delete it again. Needs a server and a session (see
/// PlaybackUITests), and the relay's two tracks of "Video 5 timer gammel"
/// already in the server's cache, so nothing has to come from YouTube.
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
        let size = app.staticTexts.matching(NSPredicate(format: "label MATCHES '.*[0-9] (kB|MB|GB)( · [0-9]+p)?'")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 120), "the whole file arrives, with its size shown")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'På denne enhed'")).firstMatch.exists, "the space used is shown")
        snapshot("offline-02-ready")

        row.tap()
        sleep(6)
        snapshot("offline-03-playing")
        XCTAssertFalse(app.staticTexts["Videoen kunne ikke afspilles."].exists, "the copy on the device plays")
        // A tap shows the controls, or hides them if they are still up.
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Luk', 'Close'}")).firstMatch
        for _ in 0..<4 where !(close.exists && close.isHittable) {
            app.tap()
            sleep(1)
        }
        XCTAssertTrue(close.isHittable, "the player can be closed")
        close.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back on Downloads")

        if UIDevice.current.userInterfaceIdiom == .pad {
            // The iPad's rows have a delete button at the right.
            let delete = app.buttons["delete-day01xxxxxx"]
            XCTAssertTrue(delete.exists, "a delete button on the row")
            XCTAssertGreaterThan(delete.frame.minX, row.frame.maxX, "at the right of the video")
            delete.tap()
        } else {
            row.swipeLeft()
            let delete = app.buttons["Slet"]
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "a swipe offers Delete")
            delete.tap()
        }
        XCTAssertTrue(app.staticTexts["Ingen downloads"].waitForExistence(timeout: 5), "deleted, nothing is left")
        snapshot("offline-04-deleted")
    }

    /// Watched to the end with the server out of reach, then back: the video
    /// leaves Main at once, and the server hears of it when the app is back
    /// in front with the server there. The server is taken away and brought
    /// back from outside the test: it signals through files in
    /// YTZERO_UITEST_SIGNALS ("ready", then waits for "offline"; "played",
    /// then waits for "online"). Needs the relay's two tracks of a short
    /// "Video 5 timer gammel" in the server's cache and no copy of it on the
    /// device yet.
    func testFinishedOfflineReachesTheServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"],
              let signals = environment["YTZERO_UITEST_SIGNALS"].map(URL.init(fileURLWithPath:)) else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER, YTZERO_UITEST_TOKEN and YTZERO_UITEST_SIGNALS, and drive the server from outside.")
        }
        func signal(_ name: String) { FileManager.default.createFile(atPath: signals.appending(path: name).path, contents: nil) }
        func waitFor(_ name: String) -> Bool {
            for _ in 0..<120 {
                if FileManager.default.fileExists(atPath: signals.appending(path: name).path) { return true }
                sleep(1)
            }
            return false
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
        app.buttons["Download"].tap()
        app.buttons["menu-button"].tap()
        app.buttons["Downloads"].tap()
        let row = app.buttons["download-day01xxxxxx"]
        let size = app.staticTexts.matching(NSPredicate(format: "label MATCHES '.*[0-9] (kB|MB)'")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 60), "the copy arrives")

        signal("ready")
        XCTAssertTrue(waitFor("offline"), "the server was taken away")
        row.tap()
        // Eight seconds of video, then the player closes by itself.
        sleep(14)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "played to the end and back on Downloads")
        snapshot("offline-sync-01-played")

        signal("played")
        XCTAssertTrue(waitFor("online"), "the server is back")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        sleep(6)
        app.buttons["menu-button"].tap()
        app.buttons["Main"].tap()
        XCTAssertTrue(app.staticTexts["I dag"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Video 1 timer gammel'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Video 5 timer gammel'")).firstMatch.exists,
                       "watched offline: gone from Main")
        snapshot("offline-sync-02-main")
        signal("done")
    }

    /// The settings, locking, deleting all and deleting once watched. Needs
    /// the relay's 720p tracks of "Video 5 timer gammel" and "Video 1 timer
    /// gammel" (eight seconds each) in the server's cache, and no copies on
    /// the device yet.
    func testSettingsLockAndDeleteAll() throws {
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
        let card = { (title: String) in app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch }
        func openDownloads() {
            app.buttons["menu-button"].tap()
            app.buttons["Downloads"].tap()
        }

        // 720p for what is downloaded from now on.
        openDownloads()
        app.buttons["download-settings"].tap()
        XCTAssertTrue(app.buttons["720p"].waitForExistence(timeout: 5), "the settings offer the quality")
        app.buttons["720p"].tap()
        let toggle = app.switches["delete-when-watched"]
        XCTAssertTrue(toggle.exists)
        // Off to begin with, whatever an earlier run left.
        if toggle.value as? String == "1" { toggle.switches.firstMatch.tap() }
        XCTAssertTrue(app.buttons["keep-days"].exists || app.otherElements["keep-days"].exists, "how long copies stay")
        snapshot("settings-01")
        app.buttons["Færdig"].tap()

        app.buttons["menu-button"].tap()
        app.buttons["Main"].tap()
        for title in ["Video 5 timer gammel", "Video 1 timer gammel"] {
            XCTAssertTrue(card(title).waitForExistence(timeout: 10))
            card(title).press(forDuration: 1.2)
            app.buttons["Download"].tap()
        }
        openDownloads()
        let five = app.buttons["download-day01xxxxxx"]
        let one = app.buttons["download-day00xxxxxx"]
        let ready = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' · 720p'"))
        for _ in 0..<60 where ready.count < 2 { sleep(1) }
        XCTAssertEqual(ready.count, 2, "both arrive, made at 720p")

        // Swipe right to lock.
        five.swipeRight()
        let lock = app.buttons["Lås"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), "a swipe to the right offers Lock")
        lock.tap()
        XCTAssertTrue(app.images["Låst"].waitForExistence(timeout: 5) || app.otherElements["Låst"].exists, "locked shows")
        snapshot("settings-02-locked")

        // Delete all but the locked.
        app.buttons["delete-all"].tap()
        let keepLocked = app.buttons["Slet alle undtagen de låste"]
        XCTAssertTrue(keepLocked.waitForExistence(timeout: 5))
        keepLocked.tap()
        XCTAssertTrue(one.waitForNonExistence(timeout: 5), "the unlocked one went")
        XCTAssertTrue(five.exists, "the locked one stayed")

        // The swipe to delete shows a bin.
        five.swipeLeft()
        let bin = app.buttons["Slet"]
        XCTAssertTrue(bin.waitForExistence(timeout: 5))
        snapshot("settings-03-bin")
        bin.tap()
        XCTAssertTrue(app.staticTexts["Ingen downloads"].waitForExistence(timeout: 5))

        // Deleted once watched.
        app.buttons["download-settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1", "delete when watched is on")
        app.buttons["Færdig"].tap()
        app.buttons["menu-button"].tap()
        app.buttons["Main"].tap()
        XCTAssertTrue(card("Video 5 timer gammel").waitForExistence(timeout: 10))
        card("Video 5 timer gammel").press(forDuration: 1.2)
        app.buttons["Download"].tap()
        openDownloads()
        XCTAssertTrue(ready.firstMatch.waitForExistence(timeout: 60))
        five.tap()
        sleep(14)
        XCTAssertTrue(app.staticTexts["Ingen downloads"].waitForExistence(timeout: 20), "watched to the end, it went by itself")
        snapshot("settings-04-gone")

        // As it was, for the other tests.
        app.buttons["download-settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.tap()
        app.buttons["1080p"].tap()
        app.buttons["Færdig"].tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
