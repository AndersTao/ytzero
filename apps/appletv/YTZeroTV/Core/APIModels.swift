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

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    struct AuthStatus: Decodable, Sendable {
        let authenticated: Bool
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
