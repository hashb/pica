import Foundation

/// Central place for user-defaults keys and typed accessors.
enum Prefs {
    enum Key {
        static let roots = "roots"
        static let selectedFolder = "selectedFolder"
        static let deletedFolder = "deletedFolderPath"
        static let favoritesFolder = "favoritesFolderPath"
        static let ffmpegPath = "ffmpegPath"
        static let autoplay = "autoplayVideos"
        static let loop = "loopVideos"
        static let scrubSpeed = "scrubBaseSpeed"
        static let upscale = "upscaleSmallImages"
        static let showNames = "showFileNames"
        static let thumbSize = "thumbnailSize"
        static let includeSubfolders = "includeSubfolders"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let filter = "mediaFilter"
        static let muted = "videoMuted"
        static let volume = "videoVolume"
        static let showFilmstrip = "showFilmstrip"
        static let viewerBackground = "viewerBackground"
        static let viewerOpacity = "viewerBackgroundOpacity"
        static let viewerFullScreen = "viewerFullScreen"
        static let emptyDeletedOnQuit = "emptyDeletedOnQuit"
    }

    static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            Key.autoplay: true,
            Key.loop: false,
            Key.scrubSpeed: 2.0,
            Key.upscale: false,
            Key.showNames: true,
            Key.thumbSize: 170.0,
            Key.sortAscending: true,
            Key.volume: 1.0,
            Key.showFilmstrip: true,
            Key.viewerBackground: ViewerBackground.translucent.rawValue,
            Key.viewerOpacity: 0.78,
            Key.viewerFullScreen: true,
            Key.emptyDeletedOnQuit: EmptyOnQuit.ask.rawValue,
        ])
    }

    static var picturesDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
    }

    static var defaultDeletedFolder: URL {
        picturesDirectory.appendingPathComponent("Pica", isDirectory: true)
            .appendingPathComponent("Deleted", isDirectory: true).folderURL
    }

    static var defaultFavoritesFolder: URL {
        picturesDirectory.appendingPathComponent("Pica", isDirectory: true)
            .appendingPathComponent("Favorites", isDirectory: true).folderURL
    }

    static var autoplay: Bool { d.bool(forKey: Key.autoplay) }
    static var loop: Bool { d.bool(forKey: Key.loop) }
    static var upscale: Bool { d.bool(forKey: Key.upscale) }
    static var viewerBackground: ViewerBackground {
        ViewerBackground(rawValue: d.string(forKey: Key.viewerBackground) ?? "") ?? .translucent
    }
    /// Open the viewer as a see-through overlay over the whole screen (otherwise inside the window).
    static var viewerFullScreen: Bool { d.bool(forKey: Key.viewerFullScreen) }
    static var emptyDeletedOnQuit: EmptyOnQuit {
        get { EmptyOnQuit(rawValue: d.string(forKey: Key.emptyDeletedOnQuit) ?? "") ?? .ask }
        set { d.set(newValue.rawValue, forKey: Key.emptyDeletedOnQuit) }
    }
    static var scrubBaseSpeed: Double { max(0.5, d.double(forKey: Key.scrubSpeed)) }
}

/// How the viewer is drawn behind the photo or video.
enum ViewerBackground: String, CaseIterable, Identifiable {
    /// The desktop shows through, dimmed (like Picasa's photo viewer).
    case translucent
    /// The desktop shows through, blurred and dimmed.
    case blurred
    /// Solid black.
    case black

    var id: String { rawValue }
    var title: String {
        switch self {
        case .translucent: "Translucent"
        case .blurred: "Blurred"
        case .black: "Black"
        }
    }
    var seeThrough: Bool { self != .black }
}
