import XCTest

/// What the Apple TV app gained to match the LG TV app: Refresh and the
/// profile picture at the top of the sidebar, so Up from a screen goes
/// straight to the places; a Saved for later row on Main; Subscriptions with
/// the channels' videos; and Mark as watched / Reject while a video plays.
/// Needs the dev data: a followed channel "Dagskanal" and a video saved for later.
@MainActor
final class ParityUITests: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"] else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER and YTZERO_UITEST_TOKEN to run against a server.")
        }
        guard #available(tvOS 27, *) else { throw XCTSkip("The sidebar has Refresh and the profile picture from tvOS 27.") }
        app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        app.launch()
    }

    private var focused: XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private var place: String {
        focused.elementType == .cell ? focused.staticTexts.firstMatch.label : ""
    }

    func testUpGoesToTheSidebarWithRefreshAndProfile() throws {
        XCTAssertTrue(app.waitForVideoFocus(), "the remote should end up on a video")
        XCTAssertTrue(app.staticTexts["Gemt til senere"].exists, "Main should have the Saved for later row")
        snapshot("parity-01-main")

        remote.press(.up); sleep(2)
        XCTAssertEqual(place, "Main", "Up from the first row should open the sidebar on Main, not a Refresh button")
        snapshot("parity-02-sidebar")

        // Above the places: the profile picture and Refresh.
        for _ in 0..<3 where focused.identifier != "refresh-button" {
            remote.press(.up); sleep(1)
        }
        XCTAssertEqual(focused.identifier, "refresh-button", "Refresh should be at the top of the sidebar")
        remote.press(.up); sleep(1)
        XCTAssertEqual(focused.identifier, "profile-button", "the profile picture should be above Refresh")
        snapshot("parity-03-sidebar-header")
        remote.press(.down); sleep(1)
        remote.press(.select); sleep(3)
        snapshot("parity-04-refreshed")
    }

    func testSubscriptionsOpenAChannel() throws {
        XCTAssertTrue(app.waitForVideoFocus(), "the remote should end up on a video")
        remote.press(.up); sleep(2)
        for _ in 0..<8 where place != "Abonnementer" {
            remote.press(.down); sleep(1)
        }
        XCTAssertEqual(place, "Abonnementer")
        remote.press(.select); sleep(3)
        XCTAssertTrue(app.staticTexts["Dagskanal"].waitForExistence(timeout: 10), "the followed channel should be listed")
        snapshot("parity-05-subscriptions")
        remote.press(.select); sleep(3)
        XCTAssertTrue(app.waitForVideoFocus(), "the channel's videos should be shown")
        snapshot("parity-06-channel")
        remote.press(.menu); sleep(2)
        XCTAssertTrue(app.staticTexts["Dagskanal"].exists, "Menu should go back to the channels")
    }

    func testHoldSelectInThePlayerOffersMarkWatchedAndReject() throws {
        XCTAssertTrue(app.waitForVideoFocus(), "the remote should end up on a video")
        remote.press(.select)
        sleep(20)
        remote.press(.select, forDuration: 1.5)
        sleep(2)
        XCTAssertTrue(app.buttons["Markér som set"].waitForExistence(timeout: 5), "holding Select should offer Mark as watched")
        XCTAssertTrue(app.buttons["Afvis"].exists, "and Reject")
        snapshot("parity-07-player-actions")
        remote.press(.menu); sleep(1)
        remote.press(.menu); sleep(3)
        XCTAssertTrue(app.waitForVideoFocus(), "back on Main")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
