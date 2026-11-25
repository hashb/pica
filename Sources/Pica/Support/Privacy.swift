import Foundation

/// Removes everything Pica writes about your files: converted videos, thumbnails, decoded images,
/// per-app system caches and saved window state. Runs when Pica quits, and again at launch in case
/// it was force-quit or crashed. Settings (sidebar folders, preferences) are kept.
enum Privacy {
    static func purge(
        bundleID: String = Bundle.main.bundleIdentifier ?? "local.pica.viewer",
        cacheRoot: URL = FFmpeg.cacheRoot,
        library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    ) {
        FFmpeg.terminateAll()

        let fm = FileManager.default
        var targets: [URL] = [
            cacheRoot,                                                              // ~/Library/Caches/Pica
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
            library.appendingPathComponent("HTTPStorages/\(bundleID)"),
            library.appendingPathComponent("Logs/Pica"),
        ]
        if let darwinCache = darwinUserCacheDirectory, library == fm.urls(for: .libraryDirectory, in: .userDomainMask)[0] {
            targets.append(darwinCache.appendingPathComponent(bundleID))              // Metal shader caches etc.
        }
        for url in targets where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        // Open/save panels remember the last folder they showed.
        let defaults = UserDefaults.standard
        if let domain = defaults.persistentDomain(forName: bundleID) {
            for key in domain.keys where key.hasPrefix("NSNav") {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The per-user cache folder under /var/folders (`getconf DARWIN_USER_CACHE_DIR`).
    private static var darwinUserCacheDirectory: URL? {
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
