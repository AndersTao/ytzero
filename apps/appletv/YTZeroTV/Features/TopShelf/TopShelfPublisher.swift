import TVServices
import UIKit

/// Keeps the Top Shelf in step with the home screen: Continue watching,
/// Saved for later and the newest of Main, each video with its picture saved as a file next to
/// the snapshot, since the Top Shelf cannot fetch it through the server
/// itself. Pictures already saved are kept; those no longer shown are removed.
enum TopShelfPublisher {
    /// How many videos each section holds.
    private static let perSection = 10
    /// Wide enough for a Top Shelf picture at 2x.
    private static let pictureWidth: CGFloat = 800

    static func publish(continueWatching: [Video], savedForLater: [Video] = [], main: [Video], client: APIClient) async {
        guard let directory = TopShelfSnapshot.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sections: [TopShelfSnapshot.Section] = []
        for (title, videos) in [
            (String(localized: "Continue watching"), continueWatching),
            (String(localized: "Saved for later"), savedForLater),
            (String(localized: "Main"), main),
        ] {
            var items: [TopShelfSnapshot.Item] = []
            for video in videos.prefix(perSection) {
                items.append(TopShelfSnapshot.Item(
                    id: video.id,
                    title: video.title,
                    channel: video.channelTitle,
                    progress: video.progress,
                    image: await picture(for: video, in: directory, client: client)
                ))
            }
            if !items.isEmpty { sections.append(TopShelfSnapshot.Section(title: title, items: items)) }
        }
        guard !Task.isCancelled else { return }
        try? TopShelfSnapshot(sections: sections).save()
        removePictures(in: directory, except: Set(sections.flatMap(\.items).compactMap(\.image)))
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Nothing on the Top Shelf, as after signing out.
    static func clear() {
        guard let directory = TopShelfSnapshot.directory else { return }
        try? FileManager.default.removeItem(at: directory)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// The picture's file name, saved first if it is not there yet.
    private static func picture(for video: Video, in directory: URL, client: APIClient) async -> String? {
        guard let source = video.thumbnail else { return nil }
        // Video ids are letters, digits, - and _, but not from every source.
        let name = (video.id.addingPercentEncoding(withAllowedCharacters: fileNameCharacters) ?? UUID().uuidString) + ".jpg"
        let file = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path()) { return name }
        guard let data = try? await client.imageData(for: source), let original = UIImage(data: data) else { return nil }
        let width = min(original.size.width, pictureWidth)
        let size = CGSize(width: width, height: (original.size.height * width / max(original.size.width, 1)).rounded())
        guard let jpeg = await original.byPreparingThumbnail(ofSize: size)?.jpegData(compressionQuality: 0.85),
              (try? jpeg.write(to: file, options: .atomic)) != nil else { return nil }
        return name
    }

    private static let fileNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    private static func removePictures(in directory: URL, except kept: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        for file in files where file.hasSuffix(".jpg") && !kept.contains(file) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }
}
