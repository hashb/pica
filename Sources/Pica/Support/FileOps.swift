import Foundation

extension URL {
    /// A folder URL built from a path, always with a trailing slash so folder URLs compare equal.
    static func folder(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).folderURL
    }

    /// Normalised folder form of this URL (standardised path, trailing slash).
    var folderURL: URL {
        URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true)
    }

    /// Normalised file form of this URL (standardised path, no trailing slash).
    var fileURL: URL {
        URL(fileURLWithPath: standardizedFileURL.path, isDirectory: false)
    }

    func isSameOrDescendant(of folder: URL) -> Bool {
        let p = standardizedFileURL.path
        let f = folder.standardizedFileURL.path
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    func isDescendant(of folder: URL) -> Bool {
        let p = standardizedFileURL.path
        let f = folder.standardizedFileURL.path
        return p != f && p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    var abbreviatedPath: String { (standardizedFileURL.path as NSString).abbreviatingWithTildeInPath }
}

/// Small wrapper around extended attributes. Used to remember where a moved file came from.
enum XAttr {
    static func get(_ name: String, at url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let len = getxattr(path, name, nil, 0, 0, 0)
            guard len > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: len)
            let read = getxattr(path, name, &buffer, len, 0, 0)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }

    static func set(_ name: String, _ value: String, at url: URL) {
        let bytes = Array(value.utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = setxattr(path, name, bytes, bytes.count, 0, 0)
        }
    }

    static func remove(_ name: String, at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = removexattr(path, name, 0)
        }
    }
}

enum FileOps {
    /// Returns `dir/name`, or `dir/name (1).ext`, `dir/name (2).ext`… if the name is taken.
    static func uniqueDestination(name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name, isDirectory: false)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        repeat {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(newName, isDirectory: false)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// Reference box so value types can live in NSCache.
final class Box<T>: NSObject {
    let value: T
    init(_ value: T) { self.value = value }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
