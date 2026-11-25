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

/// Lazily-expanded folder tree for the sidebar.
final class FolderNode: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { FileManager.default.displayName(atPath: url.path) }

    init(url: URL) { self.url = url.folderURL }

    lazy var children: [FolderNode]? = {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        let dirs = urls.filter { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return dirs.isEmpty ? nil : dirs.map(FolderNode.init)
    }()

    static func == (a: FolderNode, b: FolderNode) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}
