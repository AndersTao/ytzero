import Foundation

/// Responses from the YT Zero API that are not videos. Kept together because
/// each is a few fields and only exists to be decoded.
nonisolated enum APIModels {
    struct VideoList: Decodable, Sendable {
        let videos: [Video]
    }

    struct DeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let verificationURIComplete: String?
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    struct DeviceToken: Decodable, Sendable {
        let accessToken: String
        /// Joined to the session it was paired from ("Add profile").
        let linked: Bool?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case linked
        }
    }

    /// One of the profile's own playlists, as the side menu lists them.
    struct UserPlaylist: Decodable, Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
        let videoCount: Int

        enum CodingKeys: String, CodingKey {
            case id, name
            case videoCount = "video_count"
        }
    }

    struct UserPlaylists: Decodable, Sendable {
        let playlists: [UserPlaylist]
    }

    struct AuthStatus: Decodable, Sendable {
        let authenticated: Bool
        /// Whether this session may switch profile by itself. When it may not,
        /// each profile is paired with a session of its own.
        let canSwitch: Bool?
        /// Only the profile in use is shown, as the server's own picker does.
        let hideOtherProfiles: Bool?

        enum CodingKeys: String, CodingKey {
            case authenticated
            case canSwitch = "can_switch"
            case hideOtherProfiles = "hide_other_profiles"
        }
    }

    /// A profile as the server's profile lists describe it.
    struct Profile: Decodable, Sendable, Identifiable {
        let id: Int
        let name: String
        /// A path on the server, or empty without a picture.
        let avatar: String
        let avatarColor: String
        let isChild: Bool
        /// A PIN of the profile's own, only where nothing else signs in.
        let hasPin: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, avatar
            case avatarColor = "avatar_color"
            case isChild = "is_child"
            case hasPin = "has_pin"
        }
    }

    /// `/auth/device/profiles` and `/profiles`: the profiles to choose from and
    /// which one this session is.
    struct ProfileList: Decodable, Sendable {
        let activeID: Int
        let profiles: [Profile]

        enum CodingKeys: String, CodingKey {
            case activeID = "active_id"
            case profiles
        }
    }

    /// How a profile switch was answered.
    enum SwitchResult: Equatable, Sendable {
        case switched
        /// Leaving a child profile: the child lock PIN, or the profile's own PIN.
        case needsPin
        case wrongPin
        /// Too many wrong PINs: a parent has to unlock the child profile.
        case locked
        /// The server does not know the profile as one paired on this device.
        case notPaired
    }

    struct PlaybackTicket: Decodable, Sendable {
        let ticket: String
        let url: String
        let expiresIn: Double

        enum CodingKeys: String, CodingKey {
            case ticket, url
            case expiresIn = "expires_in"
        }
    }

    struct RefreshResult: Decodable, Sendable {
        let added: Int
    }
}
