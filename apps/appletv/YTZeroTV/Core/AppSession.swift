import Foundation
import Observation

/// Which server this Apple TV talks to and whether it is signed in.
///
/// The address is entered on the device and kept in user defaults; the session
/// token from pairing is kept in the Keychain, keyed by that address.
@Observable
final class AppSession {
    enum Stage: Equatable {
        case needsServer
        case needsPairing
        case ready
    }

    private static let addressKey = "serverAddress"

    private(set) var serverURL: URL?
    private(set) var token: String?

    var stage: Stage {
        if serverURL == nil { .needsServer } else if token == nil { .needsPairing } else { .ready }
    }

    var client: APIClient? {
        serverURL.map { APIClient(baseURL: $0, token: token) }
    }

    init() {
        #if DEBUG
        // UI tests hand in a server and a session instead of pairing by hand.
        let environment = ProcessInfo.processInfo.environment
        if let server = environment["YTZERO_UITEST_SERVER"].flatMap(URL.init(string:)), let token = environment["YTZERO_UITEST_TOKEN"] {
            serverURL = server
            self.token = token
            return
        }
        #endif
        if let saved = UserDefaults.standard.string(forKey: Self.addressKey), let url = URL(string: saved) {
            serverURL = url
            token = Keychain.read(account: saved)
        }
    }

    /// Turns what someone typed into a server address: adds https:// when no
    /// scheme is given and drops a trailing slash.
    static func normalisedAddress(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme, scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    func useServer(_ url: URL) {
        serverURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: Self.addressKey)
        token = Keychain.read(account: url.absoluteString)
    }

    func signedIn(with token: String) {
        guard let serverURL else { return }
        self.token = token
        Keychain.write(token, account: serverURL.absoluteString)
    }

    /// The server no longer accepts the session: pair again.
    func signOut() {
        if let serverURL { Keychain.delete(account: serverURL.absoluteString) }
        token = nil
    }

    func forgetServer() {
        signOut()
        serverURL = nil
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
    }
}
