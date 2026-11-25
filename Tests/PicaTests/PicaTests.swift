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
