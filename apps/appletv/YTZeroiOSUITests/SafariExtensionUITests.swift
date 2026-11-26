import XCTest

/// The Safari extension's popup on a YouTube video: "Save for later" goes
/// through the extension's native handler with the app's session, and the
/// server lists the video. Turns the extension on in Settings first. Needs
/// the app signed in to a server (ExtensionsUITests does that) and the same
/// server in YTZERO_UITEST_SERVER.
@MainActor
final class SafariExtensionUITests: XCTestCase {
    private let videoID = "jNQXAC9IVRw"

    func testPopupSavesForLater() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let base = URL(string: server) else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER to the server the app is signed in to.")
        }
        continueAfterFailure = false
        try await removeFromSavedForLater(videoID, base: base)
        enableExtension()

        let safari = try await openPopup()

        let save = safari.buttons["Save for later"]
        if !save.waitForExistence(timeout: 10) {
            // The first time, Safari asks to let the extension see the page.
            let allow = safari.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(save.waitForExistence(timeout: 10), "the popup:\n\(safari.debugDescription)")
        // A tap on the element itself does not reach the popup's page.
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = safari.staticTexts.matching(NSPredicate(format: "label IN {'Saved for later.', 'Already saved. It is first in the row again.'}")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "saved:\n\(safari.debugDescription)")
        let shot = XCTAttachment(screenshot: safari.screenshot())
        shot.name = "safari-popup-saved"
        shot.lifetime = .keepAlways
        add(shot)
        let saved = try await savedForLaterPlaylist(base: base)
        XCTAssertTrue(saved.contains(videoID), "in the server's Saved for later playlist: \(saved)")
    }

    /// Safari on the video, with the extension's popup open.
    private func openPopup() async throws -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(URL(string: "https://www.youtube.com/watch?v=\(videoID)")!)
        try await Task.sleep(for: .seconds(6))
        let menu = safari.buttons.matching(NSPredicate(format: "identifier IN {'PageFormatMenuButton', 'MoreMenuButton'}")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the page menu:\n\(safari.debugDescription)")
        menu.tap()
        try await Task.sleep(for: .seconds(1))
        var entry = safari.buttons.matching(NSPredicate(format: "label BEGINSWITH 'YT Zero'")).allElementsBoundByIndex.first(where: \.isHittable)
        if entry == nil {
            // Behind "Extensions" in the menu.
            if let extensions = safari.buttons.matching(NSPredicate(format: "label IN {'Extensions', 'Manage Extensions'}")).allElementsBoundByIndex.first(where: \.isHittable) {
                extensions.tap()
                try await Task.sleep(for: .seconds(1))
                entry = safari.buttons.matching(NSPredicate(format: "label BEGINSWITH 'YT Zero'")).allElementsBoundByIndex.first(where: \.isHittable)
            }
        }
        guard let entry else {
            XCTFail("YT Zero in the page menu:\n\(safari.debugDescription)")
            throw CocoaError(.featureUnsupported)
        }
        entry.tap()

        return safari
    }

    func testPopupOpensTheVideoInTheApp() async throws {
        guard ProcessInfo.processInfo.environment["YTZERO_UITEST_SERVER"] != nil else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER to the server the app is signed in to.")
        }
        continueAfterFailure = false
        enableExtension()
        let safari = try await openPopup()
        let open = safari.buttons["Open in YT Zero"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the popup:\n\(safari.debugDescription)")
        // The popup slides up; a tap while it moves misses.
        try await Task.sleep(for: .seconds(2))
        open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Safari asks before it hands the page to another app.
        let confirm = safari.buttons.matching(NSPredicate(format: "label == 'Open'")).firstMatch
        let springboardConfirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label == 'Open'")).firstMatch
        if confirm.waitForExistence(timeout: 10) {
            confirm.tap()
        } else if springboardConfirm.exists {
            springboardConfirm.tap()
        } else {
            XCTFail("Safari's question:\n\(safari.debugDescription)")
        }
        let app = XCUIApplication()
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Luk', 'Close'}")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 30), "the player in the app:\n\(app.debugDescription)")
        try await Task.sleep(for: .seconds(10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "app-from-popup"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Settings → Apps → Safari → Extensions → YT Zero → Allow Extension.
    private func enableExtension() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        // Apps → Safari → Extensions.
        for label in ["Apps", "Safari", "Extensions"] {
            let row = settings.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            let cell = settings.cells.matching(NSPredicate(format: "label == %@", label)).firstMatch
            var tries = 0
            while !(row.exists && row.isHittable) && !(cell.exists && cell.isHittable) && tries < 8 {
                settings.swipeUp()
                tries += 1
            }
            if row.exists && row.isHittable { row.tap() } else if cell.exists { cell.tap() } else {
                XCTFail("\(label) in Settings:\n\(settings.debugDescription)")
                return
            }
            sleep(1)
        }
        let entry = settings.cells.matching(NSPredicate(format: "label BEGINSWITH 'YT Zero'")).firstMatch
        if !entry.waitForExistence(timeout: 10) {
            XCTFail("YT Zero among Safari's extensions:\n\(settings.debugDescription)")
            return
        }
        entry.tap()
        let toggle = settings.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the switch:\n\(settings.debugDescription)")
        if toggle.value as? String == "0" { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
        // Let it see YouTube without asking each time, where offered.
        let youtube = settings.cells.matching(NSPredicate(format: "label CONTAINS 'youtube.com' OR label IN {'All Websites', 'Other Websites'}")).firstMatch
        if youtube.exists {
            youtube.tap()
            let allow = settings.cells["Allow"]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
    }
}
