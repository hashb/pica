import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaKind: String, Sendable {
    case image
    case video
}

struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: MediaKind
    let fileSize: Int64
    let modified: Date
    let created: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
}

enum MediaFormats {
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl",
        "pef", "ptx", "srw", "x3f", "erf", "mrw", "3fr", "fff", "iiq", "mos", "kdc", "dcr", "mef",
        "raw", "gpr",
    ]

    static let knownImageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "pjpeg", "png", "apng", "gif", "bmp", "dib", "tif", "tiff",
        "heic", "heif", "hif", "heics", "avif", "avifs", "webp", "jxl", "jp2", "j2k", "jpf", "jpx",
        "jpm", "psd", "psb", "ico", "icns", "cur", "tga", "icb", "vda", "vst", "exr", "hdr", "pic",
        "pbm", "pgm", "ppm", "pnm", "pfm", "dds", "astc", "ktx", "ktx2", "svg", "qoi", "pcx", "sgi",
        "rgb", "rgba", "bw", "xbm", "xpm", "jng", "wbmp",
    ]

    /// Video containers. Anything AVFoundation can't play is converted with ffmpeg when available.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2", "mkv", "mk3d", "webm", "avi", "wmv", "asf", "flv",
        "f4v", "mpg", "mpeg", "mpe", "mpv", "m1v", "m2v", "m2p", "ts", "mts", "m2ts", "tts", "vob",
        "ogv", "ogm", "divx", "xvid", "rm", "rmvb", "dv", "dif", "mxf", "y4m", "hevc", "h264", "264",
        "h265", "265", "ivf", "mjpeg", "mjpg", "nut", "amv",
    ]

    private static let nonMedia: Set<String> = ["pdf", "ai", "eps", "ps", "epsf", "epsi"]

    /// Everything ImageIO can decode on this system plus the extensions we know about.
    static let imageExtensions: Set<String> = {
        var set = rawExtensions.union(knownImageExtensions)
        if let ids = CGImageSourceCopyTypeIdentifiers() as? [String] {
            for id in ids {
                guard let type = UTType(id), !type.conforms(to: .pdf) else { continue }
                set.formUnion((type.tags[.filenameExtension] ?? []).map { $0.lowercased() })
            }
        }
        set.subtract(nonMedia)
        set.subtract(videoExtensions)
        return set
    }()

    static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .image), !type.conforms(to: .pdf) { return .image }
        }
        return nil
    }
}
