import Foundation
import Observation

/// Videos kept on this device to watch without a connection.
///
/// A copy is made from the server's own: the server fetches the video (its
/// Downloads, ahead of anything else it is fetching) and prepares a file
/// AVPlayer plays, then this device transfers that file with a background
/// session, which carries on while the app is away. The video, its pictures
/// and where it was watched to are kept beside the file, so the Downloads
/// screen and playback need no server; positions reached offline are handed
/// to the server once it can be reached again.
@Observable
final class OfflineStore {
    static let shared = OfflineStore()

    enum State: String, Codable {
        /// Asking the server to fetch it.
        case requesting
        /// The server is fetching it from YouTube.
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

        var id: String { video.id }
    }

    private(set) var entries: [Entry] = []
    /// Handed over by iOS when it woke the app for finished transfers.
    var backgroundCompletion: (() -> Void)?

    private var work: [String: Task<Void, Never>] = [:]
    private var transfers: OfflineTransfers!

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Offline", directoryHint: .isDirectory)
    }

    private static var index: URL { directory.appending(path: "index.json") }

    nonisolated static func file(for id: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Offline/\(id).mp4")
    }

    private init() {
        var folder = Self.directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Gigabytes of video that can be fetched again: not for iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        if let data = try? Data(contentsOf: Self.index), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        transfers = OfflineTransfers()
    }

    // MARK: Reading

    func entry(for id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    /// The file to play, once the whole of it is here.
    func playableFile(for id: String) -> URL? {
        guard entry(for: id)?.state == .ready else { return nil }
        let file = Self.file(for: id)
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
        if let existing = entry(for: video.id), existing.state != .failed { return }
        entries.removeAll { $0.id == video.id }
        entries.insert(Entry(video: video, state: .requesting, addedAt: .now), at: 0)
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
        let running = await transfers.runningIDs()
        for entry in entries where work[entry.id] == nil {
            switch entry.state {
            case .requesting, .serverFetching:
                start(entry.id, client: client)
            case .transferring where !running.contains(entry.id):
                start(entry.id, client: client)
            default:
                break
            }
        }
        await syncProgress(client: client)
    }

    func remove(_ id: String) {
        work[id]?.cancel()
        work[id] = nil
        transfers.cancel(id)
        try? FileManager.default.removeItem(at: Self.file(for: id))
        if let video = entry(for: id)?.video {
            [video.thumbnail, video.channelThumbnail].compactMap { $0 }.forEach(OfflineImages.remove)
        }
        entries.removeAll { $0.id == id }
        save()
    }

    private func start(_ id: String, client: APIClient) {
        work[id]?.cancel()
        work[id] = Task { await run(id, client: client) }
    }

    private func run(_ id: String, client: APIClient) async {
        defer { work[id] = nil }
        do {
            guard let video = entry(for: id)?.video else { return }
            await keepPictures(of: video, client: client)
            // Asked again when it was already done: the server answers at once.
            if entry(for: id)?.state == .requesting {
                try await client.requestServerDownload(id)
                update(id) { $0.state = .serverFetching }
            }
            try await waitForServer(id, client: client)
            let stream = try await preparedFile(id, client: client)
            try Task.checkCancellation()
            update(id) {
                $0.state = .transferring
                $0.progress = 0
            }
            transfers.start(id: id, url: stream)
        } catch is CancellationError {
        } catch {
            failed(id, message: Self.message(for: error))
        }
    }

    /// Until the server has the whole video: its progress shown as it goes.
    private func waitForServer(_ id: String, client: APIClient) async throws {
        update(id) { $0.state = .serverFetching }
        while true {
            try Task.checkCancellation()
            let answer = try await client.serverDownload(id)
            switch answer.download?.status {
            case "done":
                return
            case "error":
                throw OfflineError.server(answer.download?.error)
            case "deleted", nil:
                throw OfflineError.server(String(localized: "The server no longer has the video."))
            default:
                let percent = (answer.progress?.percent ?? 0) / 100
                update(id) { $0.progress = min(1, max(0, percent)) }
            }
            try await Task.sleep(for: .seconds(3))
        }
    }

    /// The address of the server's file, prepared for AVPlayer. A video in a
    /// format AVPlayer does not play is converted first, which takes a while.
    private func preparedFile(_ id: String, client: APIClient) async throws -> URL {
        let deadline = ContinuousClock.now + .seconds(30 * 60)
        while true {
            do {
                return try await client.playbackTicket(id, source: nil, start: 0).url
            } catch APIError.pending where ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func keepPictures(of video: Video, client: APIClient) async {
        for source in [video.thumbnail, video.channelThumbnail].compactMap({ $0 }) where OfflineImages.data(for: source) == nil {
            if let data = try? await client.imageData(for: source) { OfflineImages.store(data, for: source) }
        }
    }

    // MARK: From the background session

    func transferred(_ id: String, written: Int64, expected: Int64) {
        guard expected > 0 else { return }
        update(id) {
            $0.state = .transferring
            $0.progress = Double(written) / Double(expected)
        }
    }

    func finished(_ id: String, bytes: Int64) {
        update(id) {
            $0.state = .ready
            $0.progress = 1
            $0.bytes = bytes
            $0.error = nil
        }
    }

    func failed(_ id: String, message: String) {
        update(id) {
            $0.state = .failed
            $0.error = message
        }
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
        let ended = finished
        Task { await sync(video.id, finished: ended, client: client) }
    }

    func syncProgress(client: APIClient) async {
        for entry in entries where entry.unsynced {
            await sync(entry.id, finished: entry.position == nil, client: client)
        }
    }

    private func sync(_ id: String, finished: Bool, client: APIClient) async {
        guard let entry = entry(for: id), entry.unsynced else { return }
        do {
            if finished {
                try await client.markWatched(id)
            } else if let position = entry.position, let duration = entry.duration {
                try await client.saveProgress(id, position: position, duration: duration)
            }
            update(id) { $0.unsynced = false }
        } catch {}
    }

    // MARK: Keeping

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        change(&entry)
        guard entry != entries[index] else { return }
        entries[index] = entry
        // Progress changes many times a second; it is saved with the step it belongs to.
        if entry.state != .transferring && entry.state != .serverFetching || entries[index].progress == 0 { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.index, options: .atomic)
    }

    private static func message(for error: any Error) -> String {
        if case APIError.server(409, let message) = error, message == "downloads disabled" {
            return String(localized: "Downloads are off for this profile: turn on “Allow downloads for this profile” on the Downloads page on the web.")
        }
        if let error = error as? OfflineError { return error.localizedDescription }
        return error.localizedDescription
    }
}

nonisolated enum OfflineError: LocalizedError {
    case server(String?)

    var errorDescription: String? {
        switch self {
        case .server(let message): message ?? String(localized: "The server could not fetch the video.")
        }
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

    func start(id: String, url: URL) {
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        task.resume()
    }

    func cancel(_ id: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() }
        }
    }

    func runningIDs() async -> Set<String> {
        Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in OfflineStore.shared.transferred(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            refused.withLock { _ = refusedTasks.insert(downloadTask.taskIdentifier) }
            Task { @MainActor in OfflineStore.shared.failed(id, message: String(localized: "The server answered \(status).")) }
            return
        }
        // Moved now: the file at `location` is gone once this returns.
        let destination = OfflineStore.file(for: id)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor in OfflineStore.shared.finished(id, bytes: bytes) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in OfflineStore.shared.failed(id, message: message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription, let error else { return }
        let wasRefused = refused.withLock { refusedTasks.remove(task.taskIdentifier) != nil }
        // Cancelled on purpose: the entry is gone already.
        guard !wasRefused, (error as? URLError)?.code != .cancelled else { return }
        let message = error.localizedDescription
        Task { @MainActor in OfflineStore.shared.failed(id, message: message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            OfflineStore.shared.backgroundCompletion?()
            OfflineStore.shared.backgroundCompletion = nil
        }
    }
}
