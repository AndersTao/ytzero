import Foundation
import Network
import Observation

/// Videos kept on this device to watch without a connection.
///
/// The server makes the copy: the H.264 and AAC tracks the apps stream, up to
/// 1080p, put together in one MP4 without converting anything. Then this
/// device transfers the file with a background session, which carries on while
/// the app is away. The profile's own Downloads archive on the server is not
/// used: it keeps the quality the profile chose, which may need converting. The video, its pictures
/// and where it was watched to are kept beside the file, so the Downloads
/// screen and playback need no server; positions reached offline are handed
/// to the server once it can be reached again.
///
/// Each copy belongs to the profile that made it: another profile on this
/// device (a child's, say) neither sees nor plays it, and positions go to the
/// server as the profile they were reached by.
@Observable
final class OfflineStore {
    static let shared = OfflineStore()

    enum State: String, Codable {
        /// Asking the server for it.
        case requesting
        /// The server is fetching it from YouTube and putting it together.
        case serverFetching
        /// Coming from the server to this device.
        case transferring
        case ready
        case failed
    }

    struct Entry: Codable, Identifiable, Equatable {
        var video: Video
        var state: State
        /// How far the current step is, 0 to 1.
        var progress: Double = 0
        var bytes: Int64?
        var error: String?
        var addedAt: Date
        /// Where it was watched to here, when that is newer than the server's.
        var position: Double?
        var duration: Double?
        /// A position or a finish the server has not heard of yet.
        var unsynced = false
        /// The profile that made it.
        var profile: Int
        /// Locked: kept until deleted by hand, whatever the settings say.
        var pinned = false
        /// When the whole of it arrived, which the days kept count from.
        var readyAt: Date?
        /// The height it was asked for (480, 720 or 1080).
        var height: Int?
        /// Deleted after it was watched, kept only until the server hears of it.
        var gone = false

        var id: String { video.id }
    }

    /// The profile in use, which `entries` and everything else answer for.
    /// Another taking over stops the jobs started for the one before, which
    /// ask the server with that profile's session; they carry on when it is
    /// back (`resume`). Transfers already under way finish into their owner's copy.
    var profile = 0 {
        didSet {
            guard profile != oldValue else { return }
            work.values.forEach { $0.cancel() }
            work.removeAll()
        }
    }
    /// Every profile's copies.
    private var all: [Entry] = []
    /// The profile in use's copies, newest first.
    var entries: [Entry] { all.filter { $0.profile == profile && !$0.gone } }
    /// Handed over by iOS when it woke the app for finished transfers.
    var backgroundCompletion: (() -> Void)?

    private var work: [String: Task<Void, Never>] = [:]
    private var transfers: OfflineTransfers!
    /// The profile in use's session, for handing over what waited for a
    /// connection the moment there is one again.
    var client: APIClient?
    private let network = NWPathMonitor()
    private var online = true

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Offline", directoryHint: .isDirectory)
    }

    private static var index: URL { directory.appending(path: "index.json") }

    /// Where a profile's copy of a video is kept, apart from another profile's.
    /// Only an id of plain letters, digits, - and _ names a file (see
    /// `isSafe`), so no answer from a server can point it elsewhere.
    nonisolated static func file(for id: String, profile: Int) -> URL {
        let name = isSafe(id) ? id : "invalid"
        return URL.applicationSupportDirectory.appending(path: "Offline/\(profile)-\(name).mp4")
    }

    /// A video id as YouTube and Dailymotion write them.
    nonisolated static func isSafe(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The background task's name for a copy, and back.
    nonisolated static func taskName(_ id: String, profile: Int) -> String { "\(profile)/\(id)" }
    nonisolated static func copy(named name: String) -> (id: String, profile: Int)? {
        let parts = name.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let profile = Int(parts[0]) else { return nil }
        return (String(parts[1]), profile)
    }

    private init() {
        var folder = Self.directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Gigabytes of video that can be fetched again: not for iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        if let data = try? Data(contentsOf: Self.index), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            all = saved
        }
        transfers = OfflineTransfers()
        // Back online: positions and finishes reached offline go to the
        // server, and copies that stopped half way carry on.
        network.pathUpdateHandler = { path in
            let reachable = path.status == .satisfied
            Task { @MainActor in OfflineStore.shared.networkChanged(reachable: reachable) }
        }
        network.start(queue: .global(qos: .utility))
    }

    // MARK: Reading

    func entry(for id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    /// The file to play, once the whole of it is here.
    func playableFile(for id: String) -> URL? {
        guard entry(for: id)?.state == .ready else { return nil }
        let file = Self.file(for: id, profile: profile)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The video as far as it was watched, here or on the server, whichever is further.
    func resumable(_ video: Video) -> Video {
        guard let entry = entry(for: video.id), let position = entry.position, entry.unsynced || video.watchPosition == nil else { return video }
        var resumed = video
        resumed.watchPosition = position
        resumed.watchDuration = entry.duration ?? video.watchDuration
        return resumed
    }

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + ($1.state == .ready ? $1.bytes ?? 0 : 0) }
    }

    // MARK: Downloading

    func download(_ video: Video, client: APIClient) {
        guard Self.isSafe(video.id) else { return }
        if let existing = entry(for: video.id), existing.state != .failed { return }
        all.removeAll { $0.id == video.id && $0.profile == profile }
        all.insert(Entry(video: video, state: .requesting, addedAt: .now, profile: profile, height: OfflineSettings.quality), at: 0)
        save()
        start(video.id, client: client)
    }

    func retry(_ id: String, client: APIClient) {
        update(id) {
            $0.state = .requesting
            $0.progress = 0
            $0.error = nil
        }
        start(id, client: client)
    }

    /// Carries on with what was under way when the app was last closed: the
    /// server's part is asked about again, and a transfer the background
    /// session no longer has is started again. Positions kept here go to the server.
    func resume(client: APIClient) async {
        expire()
        let running = await transfers.runningNames()
        for entry in entries where work[Self.taskName(entry.id, profile: profile)] == nil {
            switch entry.state {
            case .requesting, .serverFetching:
                start(entry.id, client: client)
            case .transferring where !running.contains(Self.taskName(entry.id, profile: profile)):
                start(entry.id, client: client)
            default:
                break
            }
        }
        await syncProgress(client: client)
    }

    /// Locked, or no longer: a locked copy stays until deleted by hand.
    func togglePin(_ id: String) {
        update(id) { $0.pinned.toggle() }
    }

    /// Every copy of the profile in use, or all but the locked ones.
    func removeAll(keepingPinned: Bool) {
        for entry in entries where !(keepingPinned && entry.pinned) { remove(entry.id) }
    }

    /// Copies kept longer than the settings allow go, unless locked.
    func expire(now: Date = .now) {
        let days = OfflineSettings.keepDays
        guard days > 0 else { return }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        for entry in entries where entry.state == .ready && !entry.pinned && (entry.readyAt ?? entry.addedAt) < limit {
            remove(entry.id)
        }
    }

    func remove(_ id: String) {
        work[Self.taskName(id, profile: profile)]?.cancel()
        work[Self.taskName(id, profile: profile)] = nil
        transfers.cancel(Self.taskName(id, profile: profile))
        try? FileManager.default.removeItem(at: Self.file(for: id, profile: profile))
        let video = entry(for: id)?.video
        all.removeAll { $0.id == id && $0.profile == profile }
        // The pictures stay while another profile's copy of the video uses them.
        if let video, !all.contains(where: { $0.id == id }) {
            [video.thumbnail, video.channelThumbnail].compactMap { $0 }.forEach(OfflineImages.remove)
        }
        save()
    }

    /// Started for the profile in use, which the job keeps as its owner
    /// even if another profile takes over while it runs (see `profile`).
    private func start(_ id: String, client: APIClient) {
        let owner = profile
        let name = Self.taskName(id, profile: owner)
        work[name]?.cancel()
        work[name] = Task { await run(id, owner: owner, client: client) }
    }

    private func run(_ id: String, owner: Int, client: APIClient) async {
        let name = Self.taskName(id, profile: owner)
        defer { work[name] = nil }
        do {
            guard let video = all.first(where: { $0.id == id && $0.profile == owner })?.video else { return }
            await keepPictures(of: video, client: client)
            let height = all.first(where: { $0.id == id && $0.profile == owner })?.height ?? OfflineSettings.quality
            let stream = try await serverCopy(id, height: height, owner: owner, client: client)
            try Task.checkCancellation()
            update(id, profile: owner) {
                $0.state = .transferring
                $0.progress = 0
            }
            transfers.start(name: name, url: stream)
        } catch is CancellationError {
        } catch {
            failed(id, profile: owner, message: Self.message(for: error))
        }
    }

    /// Until the server's copy is ready, its progress shown as it goes: the
    /// address of the file then. Asked again, a copy already made is ready at once.
    private func serverCopy(_ id: String, height: Int, owner: Int, client: APIClient) async throws -> URL {
        update(id, profile: owner) { $0.state = .serverFetching }
        while true {
            try Task.checkCancellation()
            switch try await client.offlineCopy(id, height: height) {
            case .ready(let url):
                return url
            case .preparing(let progress):
                update(id, profile: owner) { $0.progress = min(1, max(0, progress ?? 0)) }
            }
            try await Task.sleep(for: .seconds(3))
        }
    }

    private func keepPictures(of video: Video, client: APIClient) async {
        for source in [video.thumbnail, video.channelThumbnail].compactMap({ $0 }) where OfflineImages.data(for: source) == nil {
            if let data = try? await client.imageData(for: source) { OfflineImages.store(data, for: source) }
        }
    }

    // MARK: From the background session

    func transferred(_ id: String, profile: Int, written: Int64, expected: Int64) {
        guard expected > 0 else { return }
        update(id, profile: profile) {
            $0.state = .transferring
            $0.progress = Double(written) / Double(expected)
        }
    }

    func finished(_ id: String, profile: Int, bytes: Int64) {
        update(id, profile: profile) {
            $0.state = .ready
            $0.progress = 1
            $0.readyAt = .now
            $0.bytes = bytes
            $0.error = nil
        }
    }

    func failed(_ id: String, profile: Int? = nil, message: String) {
        update(id, profile: profile) {
            $0.state = .failed
            $0.error = message
        }
    }

    private func networkChanged(reachable: Bool) {
        defer { online = reachable }
        guard reachable, !online, profile != 0, let client else { return }
        Task { await resume(client: client) }
    }

    // MARK: Where it was watched to

    /// Back from the player: kept here for a video on this device, and handed
    /// to the server, now or once it can be reached.
    func played(_ video: Video, finished: Bool, client: APIClient) {
        guard entry(for: video.id) != nil else { return }
        update(video.id) {
            if finished {
                $0.position = nil
                $0.video.watchPosition = nil
            } else if let position = video.watchPosition {
                $0.position = position
                $0.duration = video.watchDuration
                $0.video.watchPosition = position
                $0.video.watchDuration = video.watchDuration
            }
            $0.unsynced = true
        }
        // Gone from Main at once, also when it was played from Downloads.
        if finished { NotificationCenter.default.post(name: .offlineFinished, object: video) }
        // Set to go once watched: the file goes now; the entry stays out of
        // sight only until the server has heard the video was finished.
        if finished, OfflineSettings.deleteWhenWatched, entry(for: video.id)?.pinned == false {
            try? FileManager.default.removeItem(at: Self.file(for: video.id, profile: profile))
            update(video.id) { $0.gone = true }
        }
        let ended = finished
        Task { await sync(video.id, finished: ended, client: client) }
    }

    func syncProgress(client: APIClient) async {
        for entry in all where entry.profile == profile && entry.unsynced {
            await sync(entry.id, finished: entry.position == nil, client: client)
        }
    }

    private func sync(_ id: String, finished: Bool, client: APIClient) async {
        guard let entry = all.first(where: { $0.id == id && $0.profile == profile }), entry.unsynced else { return }
        do {
            if finished {
                try await client.markWatched(id)
            } else if let position = entry.position, let duration = entry.duration {
                try await client.saveProgress(id, position: position, duration: duration)
            }
            update(id) { $0.unsynced = false }
            // Deleted once watched: nothing is left to keep.
            if entry.gone { forget(id) }
            // The server has it now: lists asked from here on show it.
            NotificationCenter.default.post(name: .offlineSynced, object: id)
        } catch {}
    }

    // MARK: Keeping

    /// An entry deleted after it was watched, once the server has heard.
    private func forget(_ id: String) {
        let video = all.first(where: { $0.id == id && $0.profile == profile })?.video
        all.removeAll { $0.id == id && $0.profile == profile }
        if let video, !all.contains(where: { $0.id == id }) {
            [video.thumbnail, video.channelThumbnail].compactMap { $0 }.forEach(OfflineImages.remove)
        }
        save()
    }

    /// Changes the profile in use's entry, or the given profile's (a background
    /// transfer may end after a switch).
    private func update(_ id: String, profile owner: Int? = nil, _ change: (inout Entry) -> Void) {
        let owner = owner ?? profile
        guard let index = all.firstIndex(where: { $0.id == id && $0.profile == owner }) else { return }
        var entry = all[index]
        change(&entry)
        guard entry != all[index] else { return }
        all[index] = entry
        // Progress changes many times a second; it is saved with the step it belongs to.
        if entry.state != .transferring && entry.state != .serverFetching || entry.progress == 0 { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: Self.index, options: .atomic)
    }

    private static func message(for error: any Error) -> String {
        if case APIError.server(409, _) = error {
            return String(localized: "This video cannot be kept offline.")
        }
        return error.localizedDescription
    }
}

/// The background session that brings the server's files to this device.
/// It goes on while the app is suspended or quit; iOS wakes the app for the
/// end of it (see `AppDelegate`).
nonisolated final class OfflineTransfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let identifier = (Bundle.main.bundleIdentifier ?? "ytzero") + ".offline"
    private var session: URLSession!
    /// Answers that were not the file (a refused or lapsed ticket), by task.
    private let refused = NSLock()
    private var refusedTasks: Set<Int> = []

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// `name` says whose copy of which video (see `OfflineStore.taskName`).
    func start(name: String, url: URL) {
        let task = session.downloadTask(with: url)
        task.taskDescription = name
        task.resume()
    }

    func cancel(_ name: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == name }.forEach { $0.cancel() }
        }
    }

    func runningNames() async -> Set<String> {
        Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, profile) = downloadTask.taskDescription.flatMap(OfflineStore.copy(named:)) else { return }
        Task { @MainActor in OfflineStore.shared.transferred(id, profile: profile, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, profile) = downloadTask.taskDescription.flatMap(OfflineStore.copy(named:)) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            refused.withLock { _ = refusedTasks.insert(downloadTask.taskIdentifier) }
            Task { @MainActor in OfflineStore.shared.failed(id, profile: profile, message: String(localized: "The server answered \(status).")) }
            return
        }
        // Moved now: the file at `location` is gone once this returns.
        let destination = OfflineStore.file(for: id, profile: profile)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor in OfflineStore.shared.finished(id, profile: profile, bytes: bytes) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in OfflineStore.shared.failed(id, profile: profile, message: message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let (id, profile) = task.taskDescription.flatMap(OfflineStore.copy(named:)), let error else { return }
        let wasRefused = refused.withLock { refusedTasks.remove(task.taskIdentifier) != nil }
        // Cancelled on purpose: the entry is gone already.
        guard !wasRefused, (error as? URLError)?.code != .cancelled else { return }
        let message = error.localizedDescription
        Task { @MainActor in OfflineStore.shared.failed(id, profile: profile, message: message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            OfflineStore.shared.backgroundCompletion?()
            OfflineStore.shared.backgroundCompletion = nil
        }
    }
}

extension OfflineStore.Entry {
    /// Read leniently: a list written by an earlier version lacks the later fields.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        video = try container.decode(Video.self, forKey: .video)
        state = try container.decode(OfflineStore.State.self, forKey: .state)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        bytes = try container.decodeIfPresent(Int64.self, forKey: .bytes)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        position = try container.decodeIfPresent(Double.self, forKey: .position)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        unsynced = try container.decodeIfPresent(Bool.self, forKey: .unsynced) ?? false
        profile = try container.decode(Int.self, forKey: .profile)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        readyAt = try container.decodeIfPresent(Date.self, forKey: .readyAt)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        gone = try container.decodeIfPresent(Bool.self, forKey: .gone) ?? false
    }
}

/// How copies are made and kept on this device, set under Downloads.
nonisolated enum OfflineSettings {
    static let qualityKey = "offline.quality"
    static let deleteWhenWatchedKey = "offline.deleteWhenWatched"
    static let keepDaysKey = "offline.keepDays"

    static let qualities = [480, 720, 1080]
    /// 0 is for as long as wanted.
    static let keepChoices = [0, 1, 3, 7, 14, 30]

    static var quality: Int {
        let saved = UserDefaults.standard.integer(forKey: qualityKey)
        return qualities.contains(saved) ? saved : 1080
    }

    static var deleteWhenWatched: Bool { UserDefaults.standard.bool(forKey: deleteWhenWatchedKey) }
    static var keepDays: Int { UserDefaults.standard.integer(forKey: keepDaysKey) }
}

extension Notification.Name {
    /// A video kept on this device was watched to the end (object: the `Video`).
    static let offlineFinished = Notification.Name("YTZeroOfflineFinished")
    /// The server has heard of a position or a finish reached offline (object: the video id).
    static let offlineSynced = Notification.Name("YTZeroOfflineSynced")
}
