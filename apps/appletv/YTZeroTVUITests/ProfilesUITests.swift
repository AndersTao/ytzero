import XCTest

/// The profile picker in Settings, with the remote: two profiles signed in,
/// moving to the child profile and asked for the child lock PIN to leave it.
/// Needs a server whose two sessions are paired on the same device: the
/// grown-up's (YTZERO_UITEST_TOKEN) and the child's (YTZERO_UITEST_TOKENS).
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
        app.launch()
        let remote = XCUIRemote.shared
        app.waitForVideoFocus()

        // Up to the header (once: again goes on to the sidebar), right to the profile picture.
        remote.press(.up); sleep(1)
        remote.press(.right); sleep(1)
        XCTAssertTrue(app.buttons["profile-button"].hasFocus, "Right from Refresh should reach the profile picture")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Hvem ser med?"].waitForExistence(timeout: 10), "Settings should open on the profiles")
        let child = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lille'")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 10), "the child's profile should be listed")
        XCTAssertTrue(app.buttons["Tilføj profil"].exists, "a profile can be added")
        snapshot("01-picker")

        // The profile in use comes first; Down reaches the child's.
        let focused = { app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }
        for _ in 0..<4 where !focused().label.hasPrefix("Lille") {
            remote.press(.down); sleep(1)
        }
        XCTAssertTrue(focused().label.hasPrefix("Lille"), "focus should reach the child's profile, is on \(focused().label)")
        remote.press(.select)
        // A new library for the child, with the child named in the header.
        let picture = app.buttons["profile-button"]
        let showsChild = NSPredicate(format: "label == 'Lille'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: showsChild, object: picture)], timeout: 10), .completed, "the profile picture should be the child's")
        app.waitForVideoFocus()
        snapshot("02-child-home")

        // Leaving the child profile asks for the child lock PIN.
        remote.press(.up); sleep(1)
        remote.press(.right); sleep(1)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Hvem ser med?"].waitForExistence(timeout: 10))
        sleep(2)
        for _ in 0..<4 where !focused().label.hasPrefix("Far") {
            remote.press(.up); sleep(1)
        }
        remote.press(.select)
        // The PIN is asked for in an alert, with a secure field to type it in.
        XCTAssertTrue(app.alerts["Børnesikringens PIN-kode"].waitForExistence(timeout: 10), "leaving the child should ask for the PIN")
        XCTAssertTrue(app.secureTextFields.firstMatch.exists, "the PIN is typed in a secure field")
        sleep(1)
        snapshot("03-child-lock-pin")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
