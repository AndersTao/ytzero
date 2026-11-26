import Foundation
import SafariServices

/// The native side of the YT Zero Safari extension. Its popup asks here
/// whether the app is signed in and to save a video for later; the request
/// goes to the server with the session of the profile watching in the app
/// (`SharedStore`), so Safari needs neither a sign-in nor access to the
/// server.
///
/// Messages: `{ action: "status" }` answers `{ signedIn }`;
/// `{ action: "save", videoId }` answers `{ ok, already }` or `{ error,
/// message? }`, where `error` is "signedOut", "restricted", "invalid" or
/// "failed".
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let action = message?["action"] as? String
        let videoID = message?["videoId"] as? String
        let reply = Reply(context: context)
        Task {
            reply.send(await Self.answer(action: action, videoID: videoID))
        }
    }

    private static func answer(action: String?, videoID: String?) async -> Answer {
        let client = SharedStore.signedInClient()
        switch action {
        case "status":
            return .status(signedIn: client != nil)
        case "save":
            guard let client else { return .failed("signedOut") }
            guard let videoID, VideoLink.isVideoID(videoID) else { return .failed("invalid") }
            do {
                return .saved(already: try await client.saveForLater(videoID))
            } catch APIError.unauthorized {
                return .failed("signedOut")
            } catch APIError.server(status: 403, _) {
                return .failed("restricted")
            } catch {
                return .failed("failed", message: error.localizedDescription)
            }
        default:
            return .failed("invalid")
        }
    }
}

private enum Answer: Sendable {
    case status(signedIn: Bool)
    case saved(already: Bool)
    case failed(String, message: String? = nil)

    /// As the popup reads it.
    var message: [String: Any] {
        switch self {
        case .status(let signedIn): ["signedIn": signedIn]
        case .saved(let already): ["ok": true, "already": already]
        case .failed(let error, let message): message.map { ["error": error, "message": $0] } ?? ["error": error]
        }
    }
}

/// Hands the answer back to Safari, from the task that has it.
private final class Reply: @unchecked Sendable {
    private let context: NSExtensionContext

    init(context: NSExtensionContext) {
        self.context = context
    }

    func send(_ answer: Answer) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: answer.message]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
