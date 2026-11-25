import AppKit

/// What to do with the Deleted folder when Pica quits.
enum EmptyOnQuit: String, CaseIterable, Identifiable {
    case ask, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask"
        case .always: "Always empty"
        case .never: "Never"
        }
    }
}

/// Empties the Deleted folder: items on this Mac go to the macOS Trash; items on network storage
/// (which has no Trash) are deleted permanently.
enum DeletedFolderCleaner {
    struct Item {
        let url: URL
        let isNetwork: Bool
        let size: Int64
    }

    struct Result {
        var trashed = 0
        var removed = 0
        var failures: [String] = []
    }

    /// Top-level, non-hidden entries of the folder.
    static func items(in folder: URL) -> [Item] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return Item(url: url, isNetwork: v?.volumeIsLocal == false, size: size(of: url, v))
        }
    }

    private static func size(of url: URL, _ v: URLResourceValues?) -> Int64 {
        guard v?.isDirectory == true else { return Int64(v?.fileSize ?? 0) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            while let u = e.nextObject() as? URL {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    static func empty(_ items: [Item]) -> Result {
        let fm = FileManager.default
        var result = Result()
        for item in items {
            do {
                if item.isNetwork {
                    try fm.removeItem(at: item.url)
                    result.removed += 1
                } else {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    result.trashed += 1
                }
            } catch {
                result.failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Text for the quit prompt.
    static func message(for items: [Item]) -> String {
        let total = Format.bytes(items.reduce(0) { $0 + $1.size })
        let network = items.filter(\.isNetwork).count
        let local = items.count - network
        let one = items.count == 1
        let head = "There \(one ? "is" : "are") \(Library.count(items.count)) (\(total)) in your Deleted folder."
        if network == 0 {
            return "\(head) \(one ? "It" : "They")'ll be moved to the Trash."
        }
        if local == 0 {
            return "\(head) \(one ? "It's" : "They're") on network storage, which has no Trash, so \(one ? "it" : "they")'ll be deleted permanently. This can't be undone."
        }
        return "\(head) \(Library.count(local)) will be moved to the Trash. \(Library.count(network)) on network storage, which has no Trash, will be deleted permanently. This can't be undone."
    }

    /// True when macOS is quitting us for logout, restart or shutdown; we never prompt then.
    static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
}
