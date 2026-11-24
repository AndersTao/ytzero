import XCTest

/// Signing in on the phone itself: the code is approved while the app is
/// away (in the browser, as it is when approving on the same phone), and the
/// app picks the session up when it is back, with the same code rather than
/// a new one. Needs a server that lets this test approve without a sign-in
/// (a dev server with YTZERO_AUTH_DISABLE=1).
@MainActor
final class PairingUITests: XCTestCase {
    func testApprovedWhileTheAppIsAway() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["YTZERO_UITEST_SERVER"], let base = URL(string: server) else {
            throw XCTSkip("Set YTZERO_UITEST_SERVER to a server that approves without signing in.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["YTZERO_UITEST_SERVER"] = server
        app.launchEnvironment["YTZERO_UITEST_PAIRING"] = "1"
        app.launchArguments += ["-AppleLanguages", "(da)", "-AppleLocale", "da_DK"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let code = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[A-Z0-9]{4}-[A-Z0-9]{4}$'")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 15), "a code to approve")
        let userCode = code.label

        // Away, as when the browser is open, for longer than a few polls.
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(8))
        var request = URLRequest(url: base.appending(path: "api/auth/device/authorize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["user_code": userCode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "approved")
        try await Task.sleep(for: .seconds(4))

        app.activate()
        XCTAssertTrue(app.buttons["menu-button"].waitForExistence(timeout: 20), "signed in with the approved code")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'netværk'")).firstMatch.exists, "no network error")
    }
}
