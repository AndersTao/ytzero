import Foundation

/// What the iPhone and iPad app shares with its Safari extension and its
/// Share extension: the server's address and the sessions, so a video can be
/// saved for later as the profile watching in the app, without signing in
/// again in Safari.
///
/// The App Group comes from the build settings (YTZERO_IOS_APP_GROUP),
/// through the YTZeroAppGroup key in the Info.plist of the app and of each
/// extension. The address lives in the group's defaults and the sessions in
/// the Keychain under the same group (see `Keychain`). On the Apple TV the
/// app keeps both to itself: its Top Shelf needs neither.
nonisolated enum SharedStore {
    /// The App Group shared with the extensions; nil on the Apple TV and in a
    /// build without one.
    static var appGroup: String? {
        #if os(iOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "YTZeroAppGroup") as? String, !group.isEmpty else { return nil }
        return group
        #else
        return nil
        #endif
    }

    /// The group's defaults where there is a group, otherwise the app's own.
    static var defaults: UserDefaults {
        appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static let addressKey = "serverAddress"

    /// The server's address as the app keeps it. An address saved before the
    /// group existed is moved there, so the extensions find it too.
    static var serverAddress: String? {
        if let address = defaults.string(forKey: addressKey) { return address }
        guard appGroup != nil, let earlier = UserDefaults.standard.string(forKey: addressKey) else { return nil }
        defaults.set(earlier, forKey: addressKey)
        return earlier
    }

    static func setServerAddress(_ address: String?) {
        if let address {
            defaults.set(address, forKey: addressKey)
        } else {
            defaults.removeObject(forKey: addressKey)
            UserDefaults.standard.removeObject(forKey: addressKey)
        }
    }

    /// The server and the session of the profile watching in the app, as an
    /// extension needs them; nil when the app is not signed in.
    static func signedInClient() -> APIClient? {
        guard let address = serverAddress, let server = URL(string: address),
              let saved = Keychain.read(account: server.absoluteString), !saved.isEmpty else { return nil }
        // What AppSession writes: the sessions of the profiles signed in here
        // and which of them is watching. An older app kept a bare token.
        struct Stored: Decodable {
            struct Profile: Decodable { let token: String }
            let active: String?
            let profiles: [Profile]
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(saved.utf8)) else {
            return APIClient(baseURL: server, token: saved)
        }
        let tokens = stored.profiles.map(\.token)
        guard let token = tokens.first(where: { $0 == stored.active }) ?? tokens.first else { return nil }
        return APIClient(baseURL: server, token: token)
    }
}
