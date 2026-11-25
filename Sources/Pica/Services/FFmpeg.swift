import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

struct ProbeInfo {
    var duration: Double?
    var videoCodec: String?
    var pixelFormat: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var audioCodec: String?
    var audioChannels: Int?
}

enum FFmpegError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "ffmpeg was not found."
        case .failed(let message): message
        }
    }
}

/// Thread-safe accumulator for process output.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()

    func appendOut(_ d: Data) { lock.withLock { outData.append(d) } }
    func appendErr(_ d: Data) {
        lock.withLock {
            errData.append(d)
            if errData.count > 64_000 { errData = errData.suffix(32_000) }
        }
    }
    var out: Data { lock.withLock { outData } }
    var err: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }
}

/// Uses a locally installed ffmpeg/ffprobe for formats AVFoundation and ImageIO can't handle:
/// remuxing or transcoding videos to MP4, grabbing thumbnails, and converting exotic images.
enum FFmpeg {
    private static let lock = NSLock()
    private static var resolved: [String: String?] = [:]
    private static var encoders: Set<String>?
    /// ffmpeg/ffprobe processes currently running, so they can be stopped when Pica quits.
    private static var running: Set<Process> = []

    /// Stops any conversion or probe still running (child processes would otherwise outlive Pica).
    static func terminateAll() {
        let procs = lock.withLock { running }
        for p in procs where p.isRunning { p.terminate() }
    }

    static func resetCache() {
        lock.withLock {
            resolved = [:]
            encoders = nil
        }
    }

    static var isAvailable: Bool { path(for: "ffmpeg") != nil }

    static func path(for tool: String) -> String? {
        if let cached = lock.withLock({ resolved[tool] }) { return cached }
        let found = locate(tool)
        lock.withLock { resolved[tool] = .some(found) }
        return found
    }

    private static func locate(_ tool: String) -> String? {
        let fm = FileManager.default
        let custom = (Prefs.d.string(forKey: Prefs.Key.ffmpegPath) ?? "").trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
                let dir = isDir.boolValue ? expanded : (expanded as NSString).deletingLastPathComponent
                let candidate = (!isDir.boolValue && tool == "ffmpeg") ? expanded : (dir as NSString).appendingPathComponent(tool)
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        let home = NSHomeDirectory()
        let dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin",
            "/etc/profiles/per-user/\(NSUserName())/bin", "\(home)/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin", "/opt/local/bin", "\(home)/.local/bin", "\(home)/bin",
            "/usr/bin",
        ]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // Last resort: ask the user's login shell (apps launched from Finder don't inherit PATH).
        if let out = runSync("/bin/zsh", ["-l", "-c", "command -v \(tool)"], timeout: 4),
           let line = out.split(separator: "\n").last.map({ String($0).trimmingCharacters(in: .whitespaces) }),
           fm.isExecutableFile(atPath: line) {
            return line
        }
        return nil
    }

    /// Runs a short command synchronously and returns stdout (nil on failure/timeout).
    static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.appendOut(d) }
        }
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        collector.appendOut(pipe.fileHandleForReading.readDataToEndOfFile())
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: collector.out, as: UTF8.self)
    }

    struct RunResult {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Runs a process asynchronously. Cancelling the task terminates the process.
    static func run(_ exe: String, _ args: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RunResult, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { h.readabilityHandler = nil; return }
                    collector.appendOut(d)
                    onOutput?(String(decoding: d, as: UTF8.self))
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { h.readabilityHandler = nil; return }
                    collector.appendErr(d)
                }
                process.terminationHandler = { p in
                    lock.withLock { _ = running.remove(p) }
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: RunResult(status: p.terminationStatus, stdout: collector.out, stderr: collector.err))
                }
                do {
                    lock.withLock { _ = running.insert(process) }
                    try process.run()
                } catch {
                    lock.withLock { _ = running.remove(process) }
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Probe

    static func probe(_ url: URL) async -> ProbeInfo? {
        guard let ffprobe = path(for: "ffprobe") else { return nil }
        guard let r = try? await run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]),
              r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any]
        else { return nil }

        var info = ProbeInfo()
        if let format = json["format"] as? [String: Any], let d = format["duration"] as? String {
            info.duration = Double(d)
        }
        for s in (json["streams"] as? [[String: Any]]) ?? [] {
            let type = s["codec_type"] as? String
            if type == "video", info.videoCodec == nil {
                if let disp = s["disposition"] as? [String: Any], (disp["attached_pic"] as? Int) == 1 { continue }
                info.videoCodec = s["codec_name"] as? String
                info.pixelFormat = s["pix_fmt"] as? String
                info.width = s["width"] as? Int
                info.height = s["height"] as? Int
                if let fr = s["avg_frame_rate"] as? String {
                    let parts = fr.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0 { info.frameRate = parts[0] / parts[1] }
                }
                if info.duration == nil, let d = s["duration"] as? String { info.duration = Double(d) }
            } else if type == "audio", info.audioCodec == nil {
                info.audioCodec = s["codec_name"] as? String
                info.audioChannels = s["channels"] as? Int
            }
        }
        return info
    }

    // MARK: Cache

    static func cacheDirectory(_ sub: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pica", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Keyed on name, size and modification date so moving a file keeps its cache entry.
    static func cacheKey(_ url: URL, _ extra: String = "") -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let s = "\(url.lastPathComponent)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(extra)"
        return SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pica", isDirectory: true)
    }

    static func cacheSize() -> Int64 {
        guard let e = FileManager.default.enumerator(at: cacheRoot, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let u = e.nextObject() as? URL {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    /// Keeps converted videos under ~20 GB by deleting the least recently used ones
    /// (the whole cache is also removed when Pica quits).
    static func pruneConverted(limit: Int64 = 20 * 1024 * 1024 * 1024) {
        let dir = cacheDirectory("converted")
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { u -> (URL, Int64, Date)? in
            guard let v = try? u.resourceValues(forKeys: keys) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (u, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: u)
            total -= size
        }
    }

    // MARK: Video conversion

    private static func availableEncoders(_ ffmpeg: String) -> Set<String> {
        if let e = lock.withLock({ encoders }) { return e }
        var set = Set<String>()
        if let out = runSync(ffmpeg, ["-hide_banner", "-encoders"], timeout: 10) {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, parts[0].count == 6 { set.insert(String(parts[1])) }
            }
        }
        lock.withLock { encoders = set }
        return set
    }

    private static func canCopyVideo(_ info: ProbeInfo?) -> Bool {
        guard let info, let codec = info.videoCodec else { return false }
        let pix = info.pixelFormat ?? "yuv420p"
        switch codec {
        case "h264": return ["yuv420p", "yuvj420p", "nv12"].contains(pix)
        case "hevc": return ["yuv420p", "yuvj420p", "yuv420p10le", "nv12", "p010le"].contains(pix)
        default: return false
        }
    }

    private static func videoEncoderArgs(_ ffmpeg: String, info: ProbeInfo?) -> [String] {
        let enc = availableEncoders(ffmpeg)
        let pixels = (info?.width ?? 1920) * (info?.height ?? 1080)
        let bitrate = pixels > 3840 * 2160 ? "60M" : pixels > 2560 * 1440 ? "35M" : pixels > 1920 * 1080 ? "20M" : pixels > 1280 * 720 ? "12M" : "6M"
        if pixels > 4096 * 2304, enc.contains("hevc_videotoolbox") {
            return ["-c:v", "hevc_videotoolbox", "-b:v", bitrate, "-tag:v", "hvc1"]
        }
        if enc.contains("h264_videotoolbox") {
            return ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-profile:v", "high"]
        }
        if enc.contains("libx264") {
            return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
        }
        return ["-c:v", "mpeg4", "-q:v", "3"]
    }

    private static func conversionArgs(input: URL, output: URL, info: ProbeInfo?, copyVideo: Bool, ffmpeg: String) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-v", "error", "-i", input.path,
                 "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-map_chapters", "-1"]
        if copyVideo {
            a += ["-c:v", "copy"]
            if info?.videoCodec == "hevc" { a += ["-tag:v", "hvc1"] }
        } else {
            a += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"]
            a += videoEncoderArgs(ffmpeg, info: info)
        }
        if let ac = info?.audioCodec, ["aac", "mp3", "alac", "ac3", "eac3"].contains(ac) {
            a += ["-c:a", "copy"]
        } else {
            a += ["-c:a", "aac", "-b:a", "192k"]
        }
        a += ["-movflags", "+faststart", "-f", "mp4", "-progress", "pipe:1", "-nostats", output.path]
        return a
    }

    /// Returns an MP4 that AVFoundation can play, remuxing (fast) or transcoding as needed.
    /// It's cached for the rest of the session; the cache is deleted when Pica quits.
    static func makePlayable(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let out = cacheDirectory("converted").appendingPathComponent(cacheKey(url) + ".mp4")
        if fm.fileExists(atPath: out.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: out.path)
            return out
        }
        guard let ffmpeg = path(for: "ffmpeg") else { throw FFmpegError.notFound }
        let info = await probe(url)
        try Task.checkCancellation()
        let duration = info?.duration ?? 0
        let tmp = cacheDirectory("converted").appendingPathComponent(cacheKey(url) + ".part.mp4")
        defer { try? fm.removeItem(at: tmp) }

        let attempts: [Bool] = canCopyVideo(info) ? [true, false] : [false]
        var lastError = ""
        for copy in attempts {
            try Task.checkCancellation()
            let args = conversionArgs(input: url, output: tmp, info: info, copyVideo: copy, ffmpeg: ffmpeg)
            let result = try await run(ffmpeg, args) { chunk in
                guard duration > 0, let r = chunk.range(of: "out_time_us=", options: .backwards) else { return }
                let digits = chunk[r.upperBound...].prefix { $0.isNumber }
                if let us = Double(digits) { progress(min(1, max(0, us / 1_000_000 / duration))) }
            }
            try Task.checkCancellation()
            if result.status == 0, fm.fileExists(atPath: tmp.path) {
                try? fm.removeItem(at: out)
                try fm.moveItem(at: tmp, to: out)
                pruneConverted()
                return out
            }
            lastError = result.stderr.split(separator: "\n").suffix(2).joined(separator: " ")
        }
        throw FFmpegError.failed(lastError.isEmpty ? "ffmpeg could not convert this file." : lastError)
    }

    // MARK: Frames & images

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Grabs a single frame (video) or decodes an image with ffmpeg, scaled to fit `maxPixel`.
    static func extractFrame(_ url: URL, at seconds: Double?, maxPixel: Int, asPNG: Bool) async -> CGImage? {
        guard let ffmpeg = path(for: "ffmpeg") else { return nil }
        let out = cacheDirectory("thumbs").appendingPathComponent(cacheKey(url, "\(maxPixel)") + (asPNG ? ".png" : ".jpg"))
        if let cg = loadCGImage(out) { return cg }
        let attempts: [Double?] = seconds != nil ? [seconds, nil] : [nil]
        for t in attempts {
            var args = ["-hide_banner", "-nostdin", "-y", "-v", "error"]
            if let t { args += ["-ss", String(format: "%.3f", t)] }
            args += ["-i", url.path, "-frames:v", "1", "-an",
                     "-vf", "scale=w=\(maxPixel):h=\(maxPixel):force_original_aspect_ratio=decrease",
                     "-update", "1"]
            if !asPNG { args += ["-q:v", "4"] }
            args.append(out.path)
            guard let r = try? await run(ffmpeg, args), r.status == 0 else { continue }
            if let cg = loadCGImage(out) { return cg }
        }
        return nil
    }

    /// Converts an image that ImageIO can't read into a cached PNG.
    static func convertImageToPNG(_ url: URL) async -> URL? {
        guard let ffmpeg = path(for: "ffmpeg") else { return nil }
        let out = cacheDirectory("images").appendingPathComponent(cacheKey(url) + ".png")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let args = ["-hide_banner", "-nostdin", "-y", "-v", "error", "-i", url.path, "-frames:v", "1", "-update", "1", out.path]
        guard let r = try? await run(ffmpeg, args), r.status == 0,
              FileManager.default.fileExists(atPath: out.path) else { return nil }
        return out
    }
}
