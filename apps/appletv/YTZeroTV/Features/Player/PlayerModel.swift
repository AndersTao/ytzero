import AVFoundation
import Foundation
import Observation

/// Plays one video from the server's native stream and keeps the server told:
/// the visit, the position every 15 seconds and on close, and completion.
@Observable
final class PlayerModel {
    enum Phase: Equatable {
        case preparing
        case playing
        case failed(String)
    }

    static let seekForward: Double = 30
    static let seekBack: Double = 15

    private(set) var phase: Phase = .preparing
    private(set) var player: AVPlayer?
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Waiting for the stream: shown as a spinner over the picture.
    private(set) var isBuffering = true
    /// "+30 s", "−15 s", pause or play, shown briefly in the middle.
    private(set) var flash: String?
    /// The bar with channel, title and time; shown while paused and briefly after a press.
    private(set) var showsOverlay = true
    private(set) var finished = false

    private var ticket: String?
    /// Why the last stream did not play, as AVPlayer put it (shown on failure).
    private var lastStreamError: String?
    private var lastSaved: Double = 0
    private var overlayToken = 0
    private var flashToken = 0

    // MARK: Lifecycle

    func start(video: Video, client: APIClient) async {
        try? await client.recordVisit(video.id)
        do {
            // Always through the server, which fetches with yt-dlp and serves
            // as it arrives — what Invidious clients such as Yattee play too.
            // The direct stream is not tried: YouTube refuses it to AVPlayer.
            //
            // Full quality first: H.264 video and AAC audio as separate tracks
            // in one HLS presentation. A resume deep into a long video waits
            // until the server has fetched that far. When it cannot be played
            // that way, the plain relay (YouTube's muxed file, 360p) still can.
            var stream: Stream?
            var item: AVPlayerItem?
            if let full = try? await preparedStream(for: video.id, client: client, source: "relay-hls", start: video.resumePosition, within: .seconds(180)) {
                stream = full
                item = await playableItem(full.url, within: .seconds(45))
                if item == nil { await client.releaseTicket(video.id, ticket: full.ticket) }
            }
            try Task.checkCancellation()
            if item == nil {
                let relay = try await preparedStream(for: video.id, client: client, source: "relay", start: 0, within: .seconds(90))
                stream = relay
                item = await playableItem(relay.url, within: .seconds(45))
            }
            ticket = stream?.ticket
            guard let item, let stream, let player else {
                phase = .failed(lastStreamError ?? String(localized: "The stream could not be loaded."))
                return
            }
            if video.resumePosition > 0 {
                await player.seek(to: CMTime(seconds: video.resumePosition, preferredTimescale: 600))
            }
            await turnOffCaptions(on: item)
            player.play()
            phase = .playing
            hideOverlaySoon()
            let renewEvery = stream.expiresIn / 2
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.track(video: video, client: client, renewEvery: renewEvery) }
                group.addTask { await self.waitForEnd(of: item, video: video, client: client) }
                await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Called when the player closes: last position, then let the stream go.
    func stop(video: Video, client: APIClient) async {
        player?.pause()
        if !finished, duration > 0, position >= 1 {
            try? await client.saveProgress(video.id, position: position, duration: duration)
        }
        if let ticket {
            await client.releaseTicket(video.id, ticket: ticket)
            self.ticket = nil
        }
    }

    /// Load a stream into the player and wait until it can play; nil when it
    /// fails or does not get there in time.
    private func playableItem(_ url: URL, within limit: Duration) async -> AVPlayerItem? {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, !Task.isCancelled {
            switch item.status {
            case .readyToPlay: return item
            case .failed:
                lastStreamError = Self.describe(item.error)
                return nil
            default: try? await Task.sleep(for: .milliseconds(250))
            }
        }
        lastStreamError = String(localized: "The stream did not start in time.")
        return nil
    }

    typealias Stream = (ticket: String, url: URL, expiresIn: Double)

    /// The server may need a moment to prepare a stream; it says so with 202.
    private func preparedStream(for id: String, client: APIClient, source: String, start: Double, within limit: Duration) async throws -> Stream {
        let deadline = ContinuousClock.now + limit
        while true {
            do {
                return try await client.playbackTicket(id, source: source, start: start)
            } catch APIError.pending where ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func track(video: Video, client: APIClient, renewEvery: Double) async {
        var lastRenewal = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let player else { continue }
            if let item = player.currentItem, item.status == .failed {
                phase = .failed(Self.describe(item.error) ?? String(localized: "The stream could not be loaded."))
                showsOverlay = true
                return
            }
            isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : position
            if let seconds = player.currentItem?.duration.seconds, seconds.isFinite { duration = seconds }
            isPlaying = player.timeControlStatus != .paused
            if isPlaying, duration > 0, abs(position - lastSaved) >= 15 {
                lastSaved = position
                try? await client.saveProgress(video.id, position: position, duration: duration)
            }
            if let ticket, renewEvery > 0, ContinuousClock.now - lastRenewal >= .seconds(renewEvery) {
                lastRenewal = .now
                try? await client.renewTicket(video.id, ticket: ticket)
            }
        }
    }

    private func waitForEnd(of item: AVPlayerItem, video: Video, client: APIClient) async {
        for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
            finished = true
            try? await client.markWatched(video.id)
            return
        }
    }

    /// AVPlayer's message with the domain and code underneath it, which is what
    /// tells a refused request (HTTP) from an unplayable file (CoreMedia).
    nonisolated static func describe(_ error: (any Error)?) -> String? {
        guard let error else { return nil }
        let outer = error as NSError
        let inner = outer.userInfo[NSUnderlyingErrorKey] as? NSError
        let detail = inner.map { "\($0.domain) \($0.code): \($0.userInfo[NSLocalizedDescriptionKey] as? String ?? $0.localizedDescription)" }
            ?? "\(outer.domain) \(outer.code)"
        return "\(outer.localizedDescription) (\(detail))"
    }

    /// Captions stay off; YouTube's streams may mark a track as default.
    private func turnOffCaptions(on item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        item.select(nil, in: group)
    }

    // MARK: Remote

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
            isPlaying = true
            showFlash("▶")
            hideOverlaySoon()
        } else {
            player.pause()
            isPlaying = false
            showFlash("❚❚")
            showsOverlay = true
        }
    }

    func seek(by delta: Double) {
        guard let player else { return }
        var target = max(0, position + delta)
        if duration > 0 { target = min(target, duration - 1) }
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        showFlash(delta > 0 ? "+\(Int(delta)) s" : "−\(Int(-delta)) s")
        showOverlayBriefly()
    }

    func showOverlayBriefly() {
        showsOverlay = true
        hideOverlaySoon()
    }

    private func hideOverlaySoon() {
        overlayToken += 1
        let token = overlayToken
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if token == overlayToken, isPlaying || player?.timeControlStatus != .paused { showsOverlay = false }
        }
    }

    private func showFlash(_ text: String) {
        flash = text
        flashToken += 1
        let token = flashToken
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            if token == flashToken { flash = nil }
        }
    }
}
