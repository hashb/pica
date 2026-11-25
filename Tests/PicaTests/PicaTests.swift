import AVFoundation
import XCTest
@testable import Pica

/// Generates small sample files with ffmpeg once per run.
enum Fixtures {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("PicaTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func make(_ name: String, _ args: [String]) throws -> URL {
        let out = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let ffmpeg = FFmpeg.path(for: "ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y"] + args + [out.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("ffmpeg could not create \(name)") }
        return out
    }

    static func mp4() throws -> URL {
        try make("clip.mp4", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "30", "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p"])
    }
}

final class FormatTests: XCTestCase {
    func testKinds() {
        for ext in ["jpg", "heic", "webp", "avif", "png", "gif", "tiff", "cr2", "nef", "dng", "psd", "qoi"] {
            XCTAssertEqual(MediaFormats.kind(for: URL(fileURLWithPath: "/x/a.\(ext)")), .image, ext)
        }
        for ext in ["mp4", "mov", "mkv", "webm", "avi", "wmv", "flv", "ts", "mts", "m2ts", "ogv", "3gp", "mpg"] {
            XCTAssertEqual(MediaFormats.kind(for: URL(fileURLWithPath: "/x/a.\(ext.uppercased())")), .video, ext)
        }
        for ext in ["txt", "pdf", "mp3", "zip", ""] {
            XCTAssertNil(MediaFormats.kind(for: URL(fileURLWithPath: "/x/a.\(ext)")), ext)
        }
    }

    func testUniqueDestinationAndOrigin() throws {
        let dir = Fixtures.dir.appendingPathComponent("unique", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.jpg")
        try Data([1]).write(to: a)
        XCTAssertEqual(FileOps.uniqueDestination(name: "a.jpg", in: dir).lastPathComponent, "a (1).jpg")
        XCTAssertEqual(FileOps.uniqueDestination(name: "b.jpg", in: dir).lastPathComponent, "b.jpg")
        XAttr.set("com.pica.test", "/some/where/a.jpg", at: a)
        XCTAssertEqual(XAttr.get("com.pica.test", at: a), "/some/where/a.jpg")
        XAttr.remove("com.pica.test", at: a)
        XCTAssertNil(XAttr.get("com.pica.test", at: a))
    }

    func testFolderURLNormalisation() {
        XCTAssertEqual(URL.folder("/tmp/x"), URL(fileURLWithPath: "/tmp/x/", isDirectory: true).folderURL)
        XCTAssertTrue(URL(fileURLWithPath: "/a/b/c.jpg").isDescendant(of: URL.folder("/a/b")))
        XCTAssertFalse(URL(fileURLWithPath: "/a/bc/c.jpg").isDescendant(of: URL.folder("/a/b")))
    }
}

final class ScrubTests: XCTestCase {
    func testSpeedRamp() {
        let long = 3600.0
        XCTAssertEqual(VideoPlayerController.scrubSpeed(heldFor: 0.1, base: 2, duration: long), 2)
        XCTAssertEqual(VideoPlayerController.scrubSpeed(heldFor: 0.8, base: 2, duration: long), 4)
        XCTAssertEqual(VideoPlayerController.scrubSpeed(heldFor: 2.5, base: 2, duration: long), 16)
        XCTAssertEqual(VideoPlayerController.scrubSpeed(heldFor: 20, base: 2, duration: long), 256)
        // Short clips are capped so they don't fly past.
        XCTAssertEqual(VideoPlayerController.scrubSpeed(heldFor: 20, base: 2, duration: 12), 4)
    }

    @MainActor
    private func readyController(_ url: URL) async throws -> VideoPlayerController {
        let c = VideoPlayerController()
        c.load(url, autoplay: false)
        for _ in 0..<200 where !c.isReady { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(c.isReady, "video did not become ready: \(c.phase)")
        return c
    }

    @MainActor
    func testHoldForwardThenBackward() async throws {
        let c = try await readyController(try Fixtures.mp4())
        XCTAssertEqual(c.duration, 30, accuracy: 0.1)

        c.pressScrub(1)
        XCTAssertTrue(c.isScrubbing)
        try await Task.sleep(for: .seconds(1.5))
        c.releaseScrub()
        XCTAssertFalse(c.isScrubbing)
        // 0.7 s at 2× + 0.8 s at 4× ≈ 4.6 s
        XCTAssertGreaterThan(c.currentTime, 3.5)
        XCTAssertLessThan(c.currentTime, 6)
        let after = c.currentTime

        c.pressScrub(-1)
        try await Task.sleep(for: .seconds(1.0))
        c.releaseScrub()
        XCTAssertLessThan(c.currentTime, after - 1.5)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(c.player.currentTime().seconds, c.currentTime, accuracy: 0.1, "player should have landed on the scrub target")
        c.stop()
    }

    @MainActor
    func testTapJumpsFiveSeconds() async throws {
        let c = try await readyController(try Fixtures.mp4())
        c.seek(to: 10)
        c.pressScrub(1)
        c.releaseScrub()
        XCTAssertEqual(c.currentTime, 15, accuracy: 0.01)
        c.pressScrub(-1)
        c.releaseScrub()
        XCTAssertEqual(c.currentTime, 10, accuracy: 0.01)
        c.stop()
    }
}

final class FFmpegTests: XCTestCase {
    func testConvertsUnsupportedContainers() async throws {
        let webm = try Fixtures.make("v.webm", ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25", "-f", "lavfi", "-i", "sine", "-t", "3", "-c:v", "libvpx-vp9", "-c:a", "libopus"])
        let avi = try Fixtures.make("v.avi", ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25", "-t", "3", "-c:v", "mpeg4"])
        let mkv = try Fixtures.make("v.mkv", ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25", "-t", "3", "-c:v", "libx264", "-pix_fmt", "yuv420p"])
        for url in [webm, avi, mkv] {
            let out = try await FFmpeg.makePlayable(url) { _ in }
            let asset = AVURLAsset(url: out)
            let playable = await VideoPlayerController.canPlayNatively(asset)
            XCTAssertTrue(playable, "\(url.lastPathComponent) → \(out.lastPathComponent) not playable")
            let d = try await asset.load(.duration).seconds
            XCTAssertEqual(d, 3, accuracy: 0.2)
        }
    }

    func testImageFallbacksAndThumbnails() async throws {
        let qoi = try Fixtures.make("i.qoi", ["-f", "lavfi", "-i", "testsrc=size=400x300", "-frames:v", "1", "-c:v", "qoi"])
        let img = await ImageLoader.decode(qoi)
        XCTAssertEqual(img?.pixelSize, CGSize(width: 400, height: 300))

        let webm = try Fixtures.make("t.webm", ["-f", "lavfi", "-i", "testsrc=size=640x480:rate=25", "-t", "2", "-c:v", "libvpx-vp9"])
        let thumb = await ThumbnailService.shared.thumbnail(for: MediaItem(url: webm, kind: .video, fileSize: 0, modified: .now, created: .now))
        XCTAssertNotNil(thumb)
        XCTAssertEqual(thumb?.duration ?? 0, 2, accuracy: 0.2)
    }
}

final class PrivacyTests: XCTestCase {
    func testPurgeRemovesCachesAndPanelHistory() throws {
        let fm = FileManager.default
        let root = Fixtures.dir.appendingPathComponent("privacy", isDirectory: true)
        try? fm.removeItem(at: root)
        let cache = root.appendingPathComponent("Caches/Pica", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let bundleID = "local.pica.viewer.purgetest"
        let leftovers = [
            cache.appendingPathComponent("converted/a.mp4"),
            cache.appendingPathComponent("thumbs/b.jpg"),
            library.appendingPathComponent("Caches/\(bundleID)/x"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState/data.data"),
            library.appendingPathComponent("Logs/Pica/log.txt"),
        ]
        for f in leftovers {
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: f)
        }
        let keep = library.appendingPathComponent("Caches/some.other.app/x")
        try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: keep)

        Privacy.purge(bundleID: bundleID, cacheRoot: cache, library: library)

        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        for f in leftovers { XCTAssertFalse(fm.fileExists(atPath: f.path), f.path) }
        XCTAssertTrue(fm.fileExists(atPath: keep.path), "must not touch other apps")
    }

    func testTerminateAllStopsRunningFFmpeg() async throws {
        guard let ffmpeg = FFmpeg.path(for: "ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let task = Task {
            try await FFmpeg.run(ffmpeg, ["-v", "error", "-re", "-f", "lavfi", "-i", "testsrc", "-t", "60", "-f", "null", "-"])
        }
        try await Task.sleep(for: .milliseconds(500))
        let start = Date()
        FFmpeg.terminateAll()
        let result = try await task.value
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

final class EmptyDeletedTests: XCTestCase {
    func testNetworkItemsArePermanentlyDeletedAndMessageWarns() throws {
        let fm = FileManager.default
        let dir = Fixtures.dir.appendingPathComponent("deleted", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: dir.appendingPathComponent("a.jpg"))
        try fm.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("folder/b.jpg"))
        try Data([1]).write(to: dir.appendingPathComponent(".DS_Store"))

        let found = DeletedFolderCleaner.items(in: dir)
        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), ["a.jpg", "folder"], "hidden files are skipped")
        XCTAssertTrue(found.allSatisfy { !$0.isNetwork }, "temp dir is on a local volume")
        XCTAssertTrue(DeletedFolderCleaner.message(for: found).contains("moved to the Trash"))
        XCTAssertFalse(DeletedFolderCleaner.message(for: found).contains("permanently"))

        // Pretend they're on network storage: they must be removed outright, not trashed.
        let network = found.map { DeletedFolderCleaner.Item(url: $0.url, isNetwork: true, size: $0.size) }
        XCTAssertTrue(DeletedFolderCleaner.message(for: network).contains("deleted permanently"))
        let result = DeletedFolderCleaner.empty(network)
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.trashed, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("a.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("folder").path))

        let mixed = [found[0], network[1]]
        let msg = DeletedFolderCleaner.message(for: mixed)
        XCTAssertTrue(msg.contains("1 item will be moved to the Trash") && msg.contains("deleted permanently"), msg)
    }
}

final class SidebarTreeTests: XCTestCase {
    func testFoldersWithoutMediaAreHidden() throws {
        let fm = FileManager.default
        let root = Fixtures.dir.appendingPathComponent("tree", isDirectory: true)
        try? fm.removeItem(at: root)
        func file(_ path: String) throws {
            let u = root.appendingPathComponent(path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: u)
        }
        func dir(_ path: String) throws {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try file("trip/day1/a.jpg")          // media two levels down
        try dir("empty")                      // nothing at all
        try file("docs/notes.txt")            // files, but no media
        try file("videos/clip.mkv")
        try file("Pica/Deleted/gone.jpg")     // only media is in an excluded folder
        try file("Pica/Favorites/fav.jpg")
        let excluded = [root.appendingPathComponent("Pica/Deleted").folderURL,
                        root.appendingPathComponent("Pica/Favorites").folderURL]

        XCTAssertTrue(MediaPresence.containsMedia(root, excluding: excluded))
        XCTAssertFalse(MediaPresence.containsMedia(root.appendingPathComponent("empty"), excluding: excluded))
        XCTAssertFalse(MediaPresence.containsMedia(root.appendingPathComponent("docs"), excluding: excluded))
        XCTAssertFalse(MediaPresence.containsMedia(root.appendingPathComponent("Pica"), excluding: excluded))

        let names = FolderNode(url: root, excluded: excluded).children?.map(\.name) ?? []
        XCTAssertEqual(names, ["trip", "videos"])
        let trip = FolderNode(url: root.appendingPathComponent("trip"), excluded: excluded)
        XCTAssertEqual(trip.children?.map(\.name), ["day1"])

        // Once the last photo is gone, the folder disappears.
        try fm.removeItem(at: root.appendingPathComponent("trip/day1/a.jpg"))
        XCTAssertEqual(FolderNode(url: root, excluded: excluded).children?.map(\.name), ["videos"])
    }

    func testTrashPromptWording() {
        let local = DeletedFolderCleaner.Item(url: URL(fileURLWithPath: "/x/a.jpg"), isNetwork: false, size: 10)
        let net = DeletedFolderCleaner.Item(url: URL(fileURLWithPath: "/x/b.jpg"), isNetwork: true, size: 10)
        XCTAssertEqual(DeletedFolderCleaner.consequence(for: [local]), "It'll be moved to the Trash.")
        XCTAssertTrue(DeletedFolderCleaner.consequence(for: [net, net]).hasPrefix("They're on network storage"))
        XCTAssertTrue(DeletedFolderCleaner.message(for: [local]).hasPrefix("There is 1 item"))
    }
}
