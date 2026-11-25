import CoreServices
import Foundation

enum FolderScanner {
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey, .isPackageKey,
    ]

    /// Lists media files in `folder` (optionally recursively), skipping hidden files, packages
    /// and any folder in `excluding`.
    static func scan(_ folder: URL, recursive: Bool, excluding: [URL]) -> [MediaItem] {
        let fm = FileManager.default
        let keySet = Set(keys)
        var result: [MediaItem] = []

        if recursive {
            let excludedPaths = Set(excluding.map { $0.standardizedFileURL.path })
            guard let e = fm.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            while let url = e.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
                if v.isDirectory == true {
                    if excludedPaths.contains(url.standardizedFileURL.path) { e.skipDescendants() }
                    continue
                }
                if let item = makeItem(url, v) { result.append(item) }
            }
        } else {
            let urls = (try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
                if let item = makeItem(url, v) { result.append(item) }
            }
        }
        return result
    }

    private static func makeItem(_ url: URL, _ v: URLResourceValues) -> MediaItem? {
        guard v.isRegularFile == true, let kind = MediaFormats.kind(for: url) else { return nil }
        return MediaItem(
            url: url.fileURL,
            kind: kind,
            fileSize: Int64(v.fileSize ?? 0),
            modified: v.contentModificationDate ?? .distantPast,
            created: v.creationDate ?? .distantPast
        )
    }
}

/// Watches a folder tree with FSEvents and calls back (coalesced) on the main queue.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init?(url: URL, callback: @escaping () -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let handler: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().callback()
        }
        guard let s = FSEventStreamCreate(
            nil, handler, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.6,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

/// Answers "does this folder (or anything under it) contain a photo or video?", stopping at the first one.
enum MediaPresence {
    /// Folders bigger than this are assumed to contain media rather than walked completely.
    static let scanLimit = 20_000

    static func containsMedia(_ folder: URL, excluding: [URL]) -> Bool {
        let excludedPaths = Set(excluding.map { $0.standardizedFileURL.path })
        if excludedPaths.contains(folder.standardizedFileURL.path) { return false }
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        var seen = 0
        while let url = e.nextObject() as? URL {
            seen += 1
            if seen > scanLimit { return true }
            // Cheap extension check first; only touch the disk for likely media.
            if MediaFormats.kind(for: url) != nil,
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
            if !excludedPaths.isEmpty, excludedPaths.contains(url.standardizedFileURL.path) {
                e.skipDescendants()
            }
        }
        return false
    }
}

/// Lazily-expanded folder tree for the sidebar. Folders with no photos or videos anywhere
/// inside them are left out, as are the Favorites/Deleted folders (shown as collections).
///
/// Nodes keep their identity across refreshes (children are reused by URL), so the sidebar's
/// selection and expansion state aren't disturbed when the tree is re-checked.
final class FolderNode: Identifiable, Hashable {
    let url: URL
    let excluded: [URL]
    var id: URL { url }
    var name: String { FileManager.default.displayName(atPath: url.path) }

    private var cached: [FolderNode]??

    init(url: URL, excluded: [URL] = []) {
        self.url = url.folderURL
        self.excluded = excluded
    }

    var children: [FolderNode]? {
        if let cached { return cached }
        let fresh = loadChildren()
        cached = .some(fresh)
        return fresh
    }

    /// Re-check this subtree next time it's shown, keeping existing child nodes where possible.
    func invalidate() {
        if case .some(let kids?) = cached { kids.forEach { $0.invalidate() } }
        previous = Dictionary(uniqueKeysWithValues: ((cached ?? nil) ?? []).map { ($0.url, $0) })
        cached = nil
    }

    private var previous: [URL: FolderNode] = [:]

    private func loadChildren() -> [FolderNode]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        let excludedURLs = excluded.map(\.folderURL)
        let dirs = urls.filter { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isDirectory == true, v?.isPackage != true else { return false }
            return !excludedURLs.contains(u.folderURL) && MediaPresence.containsMedia(u, excluding: excluded)
        }
        .map(\.folderURL)
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        defer { previous = [:] }
        return dirs.isEmpty ? nil : dirs.map { previous[$0] ?? FolderNode(url: $0, excluded: excluded) }
    }

    static func == (a: FolderNode, b: FolderNode) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}
