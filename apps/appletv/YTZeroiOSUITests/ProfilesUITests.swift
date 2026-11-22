import XCTest

/// The profile picker in Settings: two profiles signed in on this device,
/// moving to the child's and asked for the child lock PIN to leave it. Needs a
/// server and two sessions paired together, as the Apple TV's ProfilesUITests do.
@MainActor
final class ProfilesUITests: XCTestCase {
    func testSwitchProfiles() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let token = environment["YTZERO_UITEST_TOKEN"],
              let others = environment["YTZERO_UITEST_TOKENS"] else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER, YTZERO_UITEST_TOKEN and YTZERO_UITEST_TOKENS to run against a server.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_TOKEN"] = token
        app.launchEnvironment["YTZERO_UITEST_TOKENS"] = others
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let settings = app.buttons["Indstillinger"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        sleep(3)
        settings.tap()
        XCTAssertTrue(app.staticTexts["Hvem ser med?"].waitForExistence(timeout: 10), "Settings should open on the profiles")
        let child = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lille'")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 10), "the child's profile should be listed")
        XCTAssertTrue(app.buttons["Tilføj profil"].exists, "a profile can be added")
        snapshot("01-picker")

        child.tap()
        XCTAssertTrue(app.staticTexts["Fortsæt med at se"].waitForExistence(timeout: 15), "the child's library should load")
        sleep(2)
        snapshot("02-child-home")

        app.buttons["Indstillinger"].tap()
        let grownUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Far'")).firstMatch
        XCTAssertTrue(grownUp.waitForExistence(timeout: 10))
        grownUp.tap()
        XCTAssertTrue(app.staticTexts["Børnesikringens PIN-kode"].waitForExistence(timeout: 10), "leaving the child should ask for the PIN")
        snapshot("03-child-lock-pin")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
