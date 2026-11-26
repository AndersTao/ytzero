import Observation
import SwiftUI

/// A video another app asked YT Zero to play: `ytzero://play?v=…&t=…`, as the
/// Safari extension's "Open in YT Zero" sends it. Kept until the library is
/// there to play it, so a link that started the app, or came while it was
/// still signing in, is not lost.
@Observable
final class OpenedLinks {
    var pending: VideoLink?
}

/// Plays the opened link over whatever is on screen, from where Safari's
/// player had got to, or else from where it was left in YT Zero.
struct PlaysOpenedLinks: ViewModifier {
    @Environment(AppSession.self) private var session
    @Environment(OpenedLinks.self) private var links
    @State private var player = PlayerPresenter()
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            // A link from before the library was on screen.
            .task { await playPending() }
            // Not `task(id:)`: taking the link clears it, which would cancel
            // the lookup that follows.
            .onChange(of: links.pending) { _, link in
                if link != nil { Task { await playPending() } }
            }
            .alert("Could not play the video", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func playPending() async {
        guard let link = links.pending, let client = session.client else { return }
        links.pending = nil
        do {
            let video = try await video(for: link, client: client)
            guard video.isPlayable else {
                failure = String(localized: "The video cannot be played yet.")
                return
            }
            // One video at a time: the one playing closes first, and is
            // gone from the screen before the next goes up.
            PlayerPresenter.closeCurrent()
            for _ in 0..<50 where PlayerPresenter.isPlayerOnScreen {
                try? await Task.sleep(for: .milliseconds(100))
            }
            player.present(video: video, client: client, onFinished: {}, onClose: { _ in })
        } catch APIError.server(status: 403, _) {
            failure = String(localized: "This profile can only watch videos that are already in YT Zero.")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// From Continue watching when it is there, so it has its position;
    /// otherwise looked up by its id, which also adds it to the library.
    private func video(for link: VideoLink, client: APIClient) async throws -> Video {
        var video: Video
        if let started = try? await client.inProgress().first(where: { $0.id == link.videoID }) {
            video = started
        } else {
            video = try await client.videoInfo(link.videoID)
        }
        if let start = link.start {
            video.watchPosition = start
            video.watchDuration = video.watchDuration ?? video.durationSeconds
        }
        return video
    }
}
