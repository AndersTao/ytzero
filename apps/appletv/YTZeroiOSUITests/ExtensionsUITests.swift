import XCTest

/// The app's way in from Safari: the server address and session typed and
/// paired in the app reach the Share extension through the App Group, so
/// "YT Zero" in Safari's share sheet saves a video for later; and
/// `ytzero://play?v=…` (the Safari extension's "Open in YT Zero") plays it.
///
/// Signs in as a person would (the address is typed, not handed in, so it
/// is saved where the extensions look), unless an earlier run did. Needs a server that approves the
/// pairing without a sign-in (a dev server with YTZERO_AUTH_DISABLE=1) and
/// can reach YouTube to look the video up.
@MainActor
final class ExtensionsUITests: XCTestCase {
    /// "Me at the zoo": short, and always there.
    private let videoID = "jNQXAC9IVRw"

    func testShareSheetSavesAndLinkPlays() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let base = URL(string: server) else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER to a server that approves without signing in.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        try await signIn(app, server: server, base: base)
        try await removeFromSavedForLater(videoID, base: base)

        // The share sheet, from Safari.
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(URL(string: "https://www.youtube.com/watch?v=\(videoID)")!)
        try await Task.sleep(for: .seconds(6))
        let share = safari.buttons.matching(NSPredicate(format: "identifier == 'ShareButton' OR label IN {'Del', 'Share'}")).firstMatch
        if !(share.exists && share.isHittable) {
            // Behind the page menu in newer Safari.
            let menu = safari.buttons.matching(NSPredicate(format: "identifier IN {'PageFormatMenuButton', 'TabBarItemMoreButton'} OR label IN {'Page Menu', 'More', 'Sidemenu', 'Flere'}")).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "a way to the share sheet:\n\(safari.debugDescription)")
            menu.tap()
        }
        try await Task.sleep(for: .seconds(1))
        let shareChoices = safari.buttons.matching(NSPredicate(format: "identifier == 'ShareButton' OR label IN {'Del', 'Share'}")).allElementsBoundByIndex
        guard let shareInMenu = shareChoices.first(where: \.isHittable) else {
            XCTFail("Share:\n\(safari.debugDescription)")
            return
        }
        shareInMenu.tap()
        let target = safari.cells.matching(NSPredicate(format: "label == 'YT Zero'")).firstMatch
        if !target.waitForExistence(timeout: 10) {
            XCTFail("YT Zero in the share sheet:\n\(safari.debugDescription)")
        }
        target.tap()
        // The extension closes by itself once saved, so ask the server.
        var savedIDs: [String] = []
        for _ in 0..<30 where !savedIDs.contains(videoID) {
            try await Task.sleep(for: .seconds(1))
            savedIDs = try await savedForLaterPlaylist(base: base)
        }
        XCTAssertTrue(savedIDs.contains(videoID), "on the server's Saved for later row: \(savedIDs)")

        // "Open in YT Zero": the link plays the video in the app.
        app.open(URL(string: "ytzero://play?v=\(videoID)&t=5")!)
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Luk', 'Close'}")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 30), "the player opens:\n\(app.debugDescription)")
        try await Task.sleep(for: .seconds(12))
        let playing = XCTAttachment(screenshot: app.screenshot())
        playing.name = "player-from-link"
        playing.lifetime = .keepAlways
        add(playing)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error:\n\(app.debugDescription)")
    }

    private func signIn(_ app: XCUIApplication, server: String, base: URL) async throws {
        // The App Group and the Keychain outlive the app: signed in from an
        // earlier run is signed in still.
        let address = app.textFields.firstMatch
        let menu = app.buttons["menu-button"]
        _ = address.waitForExistence(timeout: 15)
        if menu.exists { return }
        XCTAssertTrue(address.exists, "the server address field")
        address.tap()
        address.typeText(server)
        app.buttons.matching(NSPredicate(format: "label IN {'Forbind', 'Connect'}")).firstMatch.tap()

        let code = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[A-Z0-9]{4}-[A-Z0-9]{4}$'")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 15), "a code to approve")
        var request = URLRequest(url: base.appending(path: "api/auth/device/authorize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["user_code": code.label])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "approved")
        XCTAssertTrue(app.buttons["menu-button"].waitForExistence(timeout: 20), "signed in")
    }
}

/// The videos in the profile's "Saved for later" playlist, watched ones too
/// (the row on Main leaves those out).
func savedForLaterPlaylist(base: URL) async throws -> [String] {
    struct Saved: Decodable {
        struct Playlist: Decodable { let id: Int }
        let playlist: Playlist?
    }
    struct Videos: Decodable {
        struct Video: Decodable { let video_id: String }
        let videos: [Video]
    }
    let (data, _) = try await URLSession.shared.data(from: base.appending(path: "api/saved-for-later"))
    guard let playlist = try JSONDecoder().decode(Saved.self, from: data).playlist else { return [] }
    let (list, _) = try await URLSession.shared.data(from: base.appending(path: "api/playlists/\(playlist.id)"))
    return try JSONDecoder().decode(Videos.self, from: list).videos.map(\.video_id)
}

/// Out of the "Saved for later" playlist, so the next save is seen as new.
func removeFromSavedForLater(_ videoID: String, base: URL) async throws {
    struct Saved: Decodable {
        struct Playlist: Decodable { let id: Int }
        let playlist: Playlist?
    }
    let (data, _) = try await URLSession.shared.data(from: base.appending(path: "api/saved-for-later"))
    guard let playlist = try JSONDecoder().decode(Saved.self, from: data).playlist else { return }
    var request = URLRequest(url: base.appending(path: "api/playlists/\(playlist.id)/videos/\(videoID)"))
    request.httpMethod = "DELETE"
    _ = try await URLSession.shared.data(for: request)
}
