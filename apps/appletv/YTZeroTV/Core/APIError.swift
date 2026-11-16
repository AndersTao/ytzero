import Foundation

nonisolated enum APIError: LocalizedError, Equatable {
    /// The session is missing or no longer accepted: pair again.
    case unauthorized
    /// The device code expired before it was approved.
    case expired
    /// Still waiting for approval, or for the server to prepare a stream.
    case pending
    case server(status: Int, message: String?)
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .unauthorized: String(localized: "Sign in again on this Apple TV.")
        case .expired: String(localized: "The code expired.")
        case .pending: String(localized: "Waiting…")
        case .server(let status, let message): message ?? String(localized: "The server answered \(status).")
        case .invalidAddress: String(localized: "That is not a valid address.")
        }
    }
}
