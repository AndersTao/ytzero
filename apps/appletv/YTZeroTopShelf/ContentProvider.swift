import TVServices

/// The Top Shelf above YT Zero on the Home Screen: Continue watching, then
/// the newest of Main, as the app last saw them. Select or Play on a video
/// opens the app and plays it. Without a snapshot (not signed in yet, or
/// nothing to show) the static Top Shelf image shows instead.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let snapshot = TopShelfSnapshot.load(), let directory = TopShelfSnapshot.directory else { return nil }
        let collections = snapshot.sections.compactMap { section -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            let items = section.items.map { item(for: $0, in: directory) }
            guard !items.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }
        guard !collections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: collections)
    }

    private func item(for video: TopShelfSnapshot.Item, in directory: URL) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: video.id)
        item.title = video.title
        item.imageShape = .hdtv
        if let image = video.image {
            item.setImageURL(directory.appending(path: image), for: [.screenScale1x, .screenScale2x])
        }
        if let progress = video.progress {
            item.playbackProgress = progress
        }
        if let url = TopShelfSnapshot.playURL(for: video.id) {
            // No page of its own to show first: both play.
            item.displayAction = TVTopShelfAction(url: url)
            item.playAction = TVTopShelfAction(url: url)
        }
        return item
    }
}
