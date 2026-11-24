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
    /// "Skipped: Sponsor", for a moment after SponsorBlock jumped past a part.
    private(set) var skipNotice: String?

    private var ticket: String?
    /// The kind of stream playing, asked for again when its ticket runs out:
    /// "relay-hls", "relay", or nil for a stream that is live now.
    private var source: String?
    private var recoveries = 0
    /// Playing a copy kept on this device, not a stream from the server.
    private(set) var isLocal = false
    /// Playing as far as the viewer is concerned: started and not paused by
    /// them. AVPlayer pauses by itself when a stream runs dry.
    private var wantsToPlay = false
    /// Why the last stream did not play, as AVPlayer put it (shown on failure).
    private var lastStreamError: String?
    private var lastSaved: Double = 0
    private var overlayToken = 0
    private var flashToken = 0
    /// SponsorBlock: the parts to jump past, which were counted, and the
    /// observer that catches the start of each as it plays.
    private var skips: [APIModels.SkipSegment] = []
    private var countedSkips: Set<String> = []
    private var skipObserver: Any?
    private var skipReport: ((APIModels.SkipSegment, Double) -> Void)?
    private var noticeToken = 0

    // MARK: Lifecycle

    /// Plays from the server, or from `localFile` when the video is kept on
    /// this device: then nothing waits on the network, which may not be
    /// there, and the server hears of the visit and the position only if it is.
    func start(video: Video, client: APIClient, localFile: URL? = nil) async {
        if let localFile {
            Task { try? await client.recordVisit(video.id) }
            await play(file: localFile, video: video, client: client)
            return
        }
        try? await client.recordVisit(video.id)
        // Asked for alongside the stream, so it is there when playing starts.
        let skipList = video.liveStatus == "live" ? nil : Task { try? await client.skipSegments(video.id) }
        do {
            // Always through the server, which fetches with yt-dlp and serves
            // as it arrives — what Invidious clients such as Yattee play too.
            // The direct stream is not tried: YouTube refuses it to AVPlayer.
            //
            // Full quality first: H.264 video and AAC audio as separate tracks
            // in one HLS presentation. For a resume deep into a long video the
            // server also starts fetching from that place. When it cannot be
            // played that way, the plain relay (YouTube's muxed file, 360p) can.
            var stream: Stream?
            var item: AVPlayerItem?
            // A stream that is live now cannot be fetched as a file: the
            // server's live path relays YouTube's own live HLS instead.
            if video.liveStatus == "live" {
                let live = try await preparedStream(for: video.id, client: client, source: nil, start: 0, within: .seconds(60))
                stream = live
                source = nil
                item = await playableItem(live.url, within: .seconds(45))
            } else if let full = try? await preparedStream(for: video.id, client: client, source: "relay-hls", start: video.resumePosition, within: .seconds(180)) {
                stream = full
                source = "relay-hls"
                item = await playableItem(full.url, within: .seconds(45))
                if item == nil {
                    // Stop it before letting the ticket go, or it keeps asking.
                    player?.replaceCurrentItem(with: nil)
                    await client.releaseTicket(video.id, ticket: full.ticket, reason: lastStreamError)
                }
            }
            try Task.checkCancellation()
            if item == nil, video.liveStatus != "live" {
                let relay = try await preparedStream(for: video.id, client: client, source: "relay", start: 0, within: .seconds(90))
                stream = relay
                source = "relay"
                item = await playableItem(relay.url, within: .seconds(45))
            }
            ticket = stream?.ticket
            guard let item, let stream, let player else {
                phase = .failed(lastStreamError ?? String(localized: "The stream could not be loaded."))
                if let stream {
                    player?.replaceCurrentItem(with: nil)
                    await client.releaseTicket(video.id, ticket: stream.ticket, reason: lastStreamError)
                    ticket = nil
                }
                return
            }
            if video.resumePosition > 0, video.liveStatus != "live" {
                await player.seek(to: CMTime(seconds: video.resumePosition, preferredTimescale: 600))
            }
            await turnOffCaptions(on: item)
            player.play()
            wantsToPlay = true
            phase = .playing
            hideOverlaySoon()
            if let skipList { startSkipping(await skipList.value ?? [], video: video, client: client) }
            let renewEvery = stream.expiresIn / 2
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.track(video: video, client: client, renewEvery: renewEvery) }
                group.addTask { await self.waitForEnd(video: video, client: client) }
                await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// A copy kept on this device: no ticket to renew and nothing to recover.
    private func play(file: URL, video: Video, client: APIClient) async {
        isLocal = true
        guard let item = await playableItem(file, within: .seconds(15)), let player else {
            phase = .failed(lastStreamError ?? String(localized: "The stream could not be loaded."))
            return
        }
        if video.resumePosition > 0 {
            await player.seek(to: CMTime(seconds: video.resumePosition, preferredTimescale: 600))
        }
        await turnOffCaptions(on: item)
        player.play()
        wantsToPlay = true
        phase = .playing
        hideOverlaySoon()
        // Offline this simply finds nothing, and the copy plays as it is.
        Task { startSkipping((try? await client.skipSegments(video.id)) ?? [], video: video, client: client) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.track(video: video, client: client, renewEvery: 0) }
            group.addTask { await self.waitForEnd(video: video, client: client) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Called when the player closes: last position, then let the stream go.
    /// Returns the video as far as it was watched, once the server has it.
    @discardableResult
    func stop(video: Video, client: APIClient) async -> Video {
        // Already paused by whoever closed the screen, as a rule (see the iOS
        // PlayerPresenter): pausing again only notifies observers again.
        if let player, player.rate != 0 { player.pause() }
        wantsToPlay = false
        stopSkipping()
        var watched = video
        if !finished, duration > 0, position >= 1 {
            try? await client.saveProgress(video.id, position: position, duration: duration)
            watched.watchPosition = position
            watched.watchDuration = duration
        }
        if let ticket {
            await client.releaseTicket(video.id, ticket: ticket)
            self.ticket = nil
        }
        return watched
    }

    /// Load a stream into the player and wait until it can play; nil when it
    /// fails or does not get there in time.
    private func playableItem(_ url: URL, within limit: Duration) async -> AVPlayerItem? {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        return await isPlayable(item, within: limit) ? item : nil
    }

    private func isPlayable(_ item: AVPlayerItem, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, !Task.isCancelled {
            switch item.status {
            case .readyToPlay: return true
            case .failed:
                lastStreamError = Self.report(item)
                return false
            default: try? await Task.sleep(for: .milliseconds(250))
            }
        }
        lastStreamError = String(localized: "The stream did not start in time.")
        return false
    }

    /// The stream's ticket ran out — the device slept through a long pause,
    /// or the server restarted and forgot it — or the stream broke off. Ask
    /// for a new ticket for the same kind of stream and carry on from the
    /// same place. A few times per video, not forever.
    private func recover(video: Video, client: APIClient, reason: String? = nil) async -> Bool {
        guard !isLocal, recoveries < 3, let player else { return false }
        recoveries += 1
        let at = position
        let resume = wantsToPlay
        guard let stream = try? await preparedStream(for: video.id, client: client, source: source, start: at, within: .seconds(90)) else { return false }
        let item = AVPlayerItem(url: stream.url)
        player.replaceCurrentItem(with: item)
        guard await isPlayable(item, within: .seconds(45)) else {
            player.replaceCurrentItem(with: nil)
            await client.releaseTicket(video.id, ticket: stream.ticket, reason: lastStreamError)
            return false
        }
        if let old = ticket { await client.releaseTicket(video.id, ticket: old, reason: reason) }
        ticket = stream.ticket
        if video.liveStatus != "live", at > 0 {
            await player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        await turnOffCaptions(on: item)
        if resume { player.play() }
        return true
    }

    typealias Stream = (ticket: String, url: URL, expiresIn: Double)

    /// The server may need a moment to prepare a stream; it says so with 202.
    private func preparedStream(for id: String, client: APIClient, source: String?, start: Double, within limit: Duration) async throws -> Stream {
        let deadline = ContinuousClock.now + limit
        while true {
            do {
                return try await client.playbackTicket(id, source: source, start: start)
            } catch APIError.pending where ContinuousClock.now < deadline {
                // The server already holds each request until it is ready or
                // a few seconds have passed, so ask again straight away.
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func track(video: Video, client: APIClient, renewEvery: Double) async {
        var lastRenewal = ContinuousClock.now
        var seenErrors = 0
        var stalledSince: ContinuousClock.Instant?
        var lastProbe = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let player else { continue }
            if let item = player.currentItem, item.status == .failed {
                let reason = Self.report(item)
                if await recover(video: video, client: client) {
                    lastRenewal = .now
                    continue
                }
                phase = .failed(reason ?? String(localized: "The stream could not be loaded."))
                showsOverlay = true
                if let ticket {
                    await client.releaseTicket(video.id, ticket: ticket, reason: reason)
                    self.ticket = nil
                }
                return
            }
            isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            // Stuck, or newly failing requests: ask whether the ticket still
            // counts. This is what a lapsed ticket looks like from here —
            // AVPlayer neither fails the item nor names the refusal; its
            // error log grows, and once what it holds runs out it pauses
            // itself with an empty buffer.
            let errorCount = player.currentItem?.errorLog()?.events.count ?? 0
            let newErrors = errorCount > seenErrors
            seenErrors = errorCount
            let starved = wantsToPlay && player.timeControlStatus == .paused && player.currentItem?.isPlaybackBufferEmpty == true
            if newErrors || isBuffering || starved {
                let since = stalledSince ?? .now
                stalledSince = since
                if let ticket, newErrors || ContinuousClock.now - since >= .seconds(4), ContinuousClock.now - lastProbe >= .seconds(10) {
                    lastProbe = .now
                    do {
                        try await client.renewTicket(video.id, ticket: ticket)
                    } catch APIError.unauthorized {
                        if await recover(video: video, client: client) {
                            lastRenewal = .now
                            stalledSince = nil
                            seenErrors = player.currentItem?.errorLog()?.events.count ?? 0
                            continue
                        }
                    } catch {}
                }
                // Stuck with a ticket the server still takes: something else
                // broke, which on an iPad on iOS 17 has looked like a black
                // picture and a spinner for good, while the same stream plays
                // on elsewhere. Load it again from the same place, as closing
                // and reopening the video does, and tell the server what
                // AVPlayer saw so the cause can be found.
                if (isBuffering || starved), ContinuousClock.now - since >= .seconds(12),
                   let item = player.currentItem,
                   await recover(video: video, client: client, reason: "stalled 12 s: " + Self.stallReport(item)) {
                    lastRenewal = .now
                    stalledSince = nil
                    seenErrors = player.currentItem?.errorLog()?.events.count ?? 0
                    continue
                }
            } else {
                stalledSince = nil
            }
            position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : position
            if let seconds = player.currentItem?.duration.seconds, seconds.isFinite { duration = seconds }
            isPlaying = player.timeControlStatus != .paused
            // Also catches a part played into by a seek, which the observer does not.
            if isPlaying { skipIfInSegment(at: position) }
            if isPlaying, duration > 0, abs(position - lastSaved) >= 15 {
                lastSaved = position
                try? await client.saveProgress(video.id, position: position, duration: duration)
            }
            if let ticket, renewEvery > 0, ContinuousClock.now - lastRenewal >= .seconds(renewEvery) {
                lastRenewal = .now
                do {
                    try await client.renewTicket(video.id, ticket: ticket)
                } catch APIError.unauthorized {
                    // Gone already (see recover); a new one before AVPlayer
                    // needs it, rather than after it has failed.
                    if await recover(video: video, client: client) { lastRenewal = .now }
                } catch {}
            }
        }
    }

    /// The end of whichever item plays: `recover` may have swapped it.
    private func waitForEnd(video: Video, client: APIClient) async {
        for await note in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification) {
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { continue }
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

    /// `describe` plus the last entry of the item's error log: the HTTP status
    /// and the request a stream failed on, which the error alone leaves out.
    static func report(_ item: AVPlayerItem) -> String? {
        var parts: [String] = []
        if let error = describe(item.error) { parts.append(error) }
        if let event = item.errorLog()?.events.last {
            var line = "log: \(event.errorDomain) \(event.errorStatusCode)"
            if let comment = event.errorComment { line += " \(comment)" }
            if let uri = event.uri, let path = URL(string: uri)?.path { line += " \(path)" }
            parts.append(line)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the player was doing when it got stuck: status, buffer, and the
    /// last entries of its error and access logs.
    static func stallReport(_ item: AVPlayerItem) -> String {
        var parts = ["status \(item.status.rawValue)", "empty \(item.isPlaybackBufferEmpty)", "keepUp \(item.isPlaybackLikelyToKeepUp)"]
        if let range = item.loadedTimeRanges.last?.timeRangeValue {
            parts.append("loaded \(Int(range.start.seconds))–\(Int(range.end.seconds)) s")
        }
        if let report = report(item) { parts.append(report) }
        if let access = item.accessLog()?.events.last {
            var line = "access: stalls \(access.numberOfStalls) segments \(access.numberOfMediaRequests) bytes \(access.numberOfBytesTransferred)"
            if let uri = access.uri, let path = URL(string: uri)?.path { line += " \(path)" }
            parts.append(line)
        }
        return parts.joined(separator: " · ")
    }

    /// Captions stay off; YouTube's streams may mark a track as default.
    private func turnOffCaptions(on item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        item.select(nil, in: group)
    }

    // MARK: SponsorBlock

    /// Jump past the profile's chosen parts (sponsors, intros, …) as the web
    /// player does: at the start of each as it plays, and whenever playing
    /// finds itself inside one.
    private func startSkipping(_ segments: [APIModels.SkipSegment], video: Video, client: APIClient) {
        stopSkipping()
        guard !segments.isEmpty, let player else { return }
        skips = segments
        skipReport = { segment, skipped in
            Task { try? await client.recordSkip(video.id, segment: segment, skipped: skipped) }
        }
        let starts = segments.map { NSValue(time: CMTime(seconds: $0.start + 0.05, preferredTimescale: 600)) }
        skipObserver = player.addBoundaryTimeObserver(forTimes: starts, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let now = self.player?.currentTime().seconds, now.isFinite else { return }
                self.skipIfInSegment(at: now)
            }
        }
        if let now = self.player?.currentTime().seconds, now.isFinite { skipIfInSegment(at: now) }
    }

    private func stopSkipping() {
        if let skipObserver { player?.removeTimeObserver(skipObserver) }
        skipObserver = nil
        skips = []
        skipReport = nil
    }

    private func skipIfInSegment(at time: Double) {
        guard wantsToPlay, let segment = skips.first(where: { time >= $0.start && time < $0.end - 0.3 }) else { return }
        let skipped = segment.end - time
        seek(to: segment.end)
        showSkipNotice(segment.category)
        if countedSkips.insert(segment.uuid).inserted { skipReport?(segment, skipped) }
    }

    private func showSkipNotice(_ category: String) {
        skipNotice = String(localized: "Skipped: \(Self.skipName(category))")
        noticeToken += 1
        let token = noticeToken
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if token == noticeToken { skipNotice = nil }
        }
    }

    /// The names the web gives SponsorBlock's kinds.
    static func skipName(_ category: String) -> String {
        switch category {
        case "sponsor": String(localized: "Sponsor")
        case "selfpromo": String(localized: "Self-promotion")
        case "interaction": String(localized: "Interaction")
        case "intro": String(localized: "Intro")
        case "outro": String(localized: "Outro")
        case "preview": String(localized: "Preview")
        case "music_offtopic": String(localized: "Non-music section")
        case "filler": String(localized: "Filler")
        default: category
        }
    }

    // MARK: Remote

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
            wantsToPlay = true
            isPlaying = true
            showFlash("▶")
            hideOverlaySoon()
        } else {
            player.pause()
            wantsToPlay = false
            isPlaying = false
            showFlash("❚❚")
            showsOverlay = true
        }
    }

    /// Jump by `delta` seconds. A double tap on the side of the picture
    /// skips quietly: it shows its own mark there, and the controls stay away.
    func seek(by delta: Double, quietly: Bool = false) {
        seek(to: position + delta)
        if quietly { return }
        showFlash(delta > 0 ? "+\(Int(delta)) s" : "−\(Int(-delta)) s")
        showOverlayBriefly()
    }

    /// Straight to a place, as dragging along the timeline does.
    func seek(to seconds: Double) {
        guard let player else { return }
        var target = max(0, seconds)
        if duration > 0 { target = min(target, duration - 1) }
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// How fast it plays, kept when pausing and playing again.
    private(set) var speed: Float = 1

    func setSpeed(_ rate: Float) {
        speed = rate
        player?.defaultRate = rate
        if let player, player.timeControlStatus != .paused { player.rate = rate }
    }

    /// A tap on the picture: the controls come up, or go away while it plays.
    func toggleOverlay() {
        if showsOverlay, isPlaying {
            overlayToken += 1
            showsOverlay = false
        } else {
            showOverlayBriefly()
        }
    }

    /// Keep the controls up while someone works them, such as dragging the
    /// timeline; they hide again a while after the last call.
    func keepOverlay() {
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
