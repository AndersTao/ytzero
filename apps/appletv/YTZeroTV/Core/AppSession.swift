import Foundation
import Observation

/// Which server this device talks to, the profiles signed in on it, and which
/// of them is watching.
///
/// The address is entered on the device and kept in user defaults. Where the
/// server pins a session to one profile (per-profile login, OIDC in mapped
/// mode), every profile is paired on its own and the device keeps a session
/// for each; where a session may switch profile by itself, there is one. The
/// sessions are kept in the Keychain, keyed by the address.
@Observable
final class AppSession {
    enum Stage: Equatable {
        case needsServer
        case needsPairing
        case ready
    }

    /// One profile signed in on this device, with what the picker shows of it.
    /// `id` is 0 until the server has said who the session belongs to.
    nonisolated struct Profile: Codable, Equatable, Identifiable, Sendable {
        var id: Int
        var name: String
        var avatar: String
        var avatarColor: String
        var isChild: Bool
        var token: String

        init(token: String) {
            self.init(id: 0, name: "", avatar: "", avatarColor: "", isChild: false, token: token)
        }

        init(id: Int, name: String, avatar: String, avatarColor: String, isChild: Bool, token: String) {
            self.id = id
            self.name = name
            self.avatar = avatar
            self.avatarColor = avatarColor
            self.isChild = isChild
            self.token = token
        }
    }

    private nonisolated struct Stored: Codable {
        var active: String?
        var profiles: [Profile]
    }

    private static let addressKey = "serverAddress"

    private(set) var serverURL: URL?
    private(set) var profiles: [Profile] = []
    private(set) var token: String?
    /// Changes whenever another profile starts watching: the library on
    /// screen belonged to the one before and starts over.
    private(set) var generation = 0

    var stage: Stage {
        if serverURL == nil { .needsServer } else if token == nil { .needsPairing } else { .ready }
    }

    var client: APIClient? {
        serverURL.map { APIClient(baseURL: $0, token: token) }
    }

    var activeProfile: Profile? {
        profiles.first { $0.token == token }
    }

    init() {
        #if DEBUG
        // UI tests hand in a server and a session instead of pairing by hand,
        // and may hand in more sessions (YTZERO_UITEST_TOKENS, comma separated)
        // to show more than one profile.
        let environment = ProcessInfo.processInfo.environment
        // A server and no session: the sign-in, as on a first launch.
        if let server = environment["YTZERO_UITEST_SERVER"].flatMap(URL.init(string:)), environment["YTZERO_UITEST_PAIRING"] == "1" {
            serverURL = server
            return
        }
        if let server = environment["YTZERO_UITEST_SERVER"].flatMap(URL.init(string:)), let token = environment["YTZERO_UITEST_TOKEN"] {
            serverURL = server
            let extra = (environment["YTZERO_UITEST_TOKENS"] ?? "").split(separator: ",").map(String.init).filter { $0 != token }
            profiles = ([token] + extra).map(Profile.init(token:))
            self.token = token
            return
        }
        #endif
        if let saved = UserDefaults.standard.string(forKey: Self.addressKey), let url = URL(string: saved) {
            serverURL = url
            load()
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
        load()
    }

    /// The first pairing on this server: the one profile there is.
    func signedIn(with token: String) {
        profiles = [Profile(token: token)]
        self.token = token
        generation += 1
        save()
    }

    /// Another profile paired from Settings. It is the one watching now.
    func added(token: String) {
        profiles.removeAll { $0.token == token }
        profiles.append(Profile(token: token))
        self.token = token
        generation += 1
        save()
    }

    /// Watch as another of the profiles signed in here.
    func activate(_ profile: Profile) {
        guard profiles.contains(where: { $0.token == profile.token }) else { return }
        token = profile.token
        generation += 1
        save()
    }

    /// The session itself switched profile (where the server lets it).
    func profileChanged() {
        generation += 1
    }

    /// Takes in what the server says about a profile: its name and picture,
    /// and, with `token`, which session is that profile's. A profile paired
    /// twice keeps its newest session, as the server does.
    func update(id: Int, name: String, avatar: String, avatarColor: String, isChild: Bool, token: String? = nil) {
        if let token, let index = profiles.firstIndex(where: { $0.token == token }) {
            profiles[index].id = id
            profiles.removeAll { $0.id == id && $0.token != token }
        }
        for index in profiles.indices where profiles[index].id == id {
            profiles[index].name = name
            profiles[index].avatar = avatar
            profiles[index].avatarColor = avatarColor
            profiles[index].isChild = isChild
        }
        save()
    }

    /// Forgets one profile's session on this device. Removing the one in use
    /// moves on to another, or back to pairing when it was the last.
    func remove(_ profile: Profile) {
        profiles.removeAll { $0.token == profile.token }
        if token == profile.token {
            token = profiles.first?.token
            generation += 1
        }
        save()
    }

    /// The server no longer accepts the session in use: drop it, and carry on
    /// with another profile if there is one.
    func signOut() {
        if let activeProfile {
            remove(activeProfile)
        } else {
            token = nil
            save()
        }
    }

    func forgetServer() {
        if let serverURL { Keychain.delete(account: serverURL.absoluteString) }
        profiles = []
        token = nil
        serverURL = nil
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
    }

    // MARK: Keychain

    private func load() {
        guard let serverURL, let saved = Keychain.read(account: serverURL.absoluteString) else {
            profiles = []
            token = nil
            return
        }
        if let stored = try? JSONDecoder().decode(Stored.self, from: Data(saved.utf8)) {
            profiles = stored.profiles
            token = stored.profiles.contains { $0.token == stored.active } ? stored.active : stored.profiles.first?.token
        } else {
            // Saved before there could be several: the bare token of one session.
            profiles = [Profile(token: saved)]
            token = saved
        }
    }

    private func save() {
        guard let serverURL else { return }
        #if DEBUG
        // A UI test's sessions are handed in for that run only.
        if ProcessInfo.processInfo.environment["YTZERO_UITEST_TOKEN"] != nil { return }
        #endif
        let account = serverURL.absoluteString
        guard !profiles.isEmpty, let data = try? JSONEncoder().encode(Stored(active: token, profiles: profiles)) else {
            Keychain.delete(account: account)
            return
        }
        Keychain.write(String(decoding: data, as: UTF8.self), account: account)
    }
}
