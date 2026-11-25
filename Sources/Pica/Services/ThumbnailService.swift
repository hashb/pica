import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing

struct Thumbnail {
    let image: NSImage
    let duration: Double?
}

/// Limits how many expensive jobs run at once. Newest requests are served first,
/// so whatever is on screen right now wins over cells that scrolled away.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.popLast() {
            next.resume()
        } else {
            running -= 1
        }
    }
}

final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()
    static let maxPixel = 512

    private let cache = NSCache<NSURL, Box<Thumbnail>>()
    private let limiter = AsyncLimiter(limit: max(4, ProcessInfo.processInfo.activeProcessorCount))

    init() { cache.countLimit = 4000 }

    func cached(_ url: URL) -> Thumbnail? { cache.object(forKey: url as NSURL)?.value }

    func thumbnail(for item: MediaItem) async -> Thumbnail? {
        if let c = cached(item.url) { return c }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }
        if let c = cached(item.url) { return c }
        let result = await Self.generate(item.url, kind: item.kind, maxPixel: Self.maxPixel)
        if let result { cache.setObject(Box(result), forKey: item.url as NSURL) }
        return result
    }

    private static func generate(_ url: URL, kind: MediaKind, maxPixel: Int) async -> Thumbnail? {
        switch kind {
        case .image:
            if let cg = imageIOThumbnail(url, maxPixel) { return Thumbnail(image: NSImage(cgImage: cg, size: .zero), duration: nil) }
            if let img = await quickLook(url, maxPixel) { return Thumbnail(image: img, duration: nil) }
            if let cg = await FFmpeg.extractFrame(url, at: nil, maxPixel: maxPixel, asPNG: true) {
                return Thumbnail(image: NSImage(cgImage: cg, size: .zero), duration: nil)
            }
            return nil
        case .video:
            let asset = AVURLAsset(url: url)
            if let r = await avThumbnail(asset, maxPixel) {
                return Thumbnail(image: NSImage(cgImage: r.0, size: .zero), duration: r.1)
            }
            let info = await FFmpeg.probe(url)
            let duration = info?.duration
            let at = duration.map { min($0 * 0.1, 5) } ?? 1
            if let cg = await FFmpeg.extractFrame(url, at: at, maxPixel: maxPixel, asPNG: false) {
                return Thumbnail(image: NSImage(cgImage: cg, size: .zero), duration: duration)
            }
            if let img = await quickLook(url, maxPixel) { return Thumbnail(image: img, duration: duration) }
            return nil
        }
    }

    static func imageIOThumbnail(_ url: URL, _ maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let base: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var embedded = base
        embedded[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, embedded as CFDictionary),
           max(cg.width, cg.height) >= maxPixel / 2 {
            return cg
        }
        var full = base
        full[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(src, 0, full as CFDictionary)
    }

    private static func avThumbnail(_ asset: AVURLAsset, _ maxPixel: Int) async -> (CGImage, Double?)? {
        let seconds = (try? await asset.load(.duration))?.seconds
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let t = duration.map { min($0 * 0.1, 5) } ?? 0
        guard let r = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { return nil }
        return (r.image, duration)
    }

    private static func quickLook(_ url: URL, _ maxPixel: Int) async -> NSImage? {
        let side = CGFloat(maxPixel) / 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

struct LoadedImage {
    let image: NSImage
    let pixelSize: CGSize
    let isAnimated: Bool
}

/// Decodes full-resolution images off the main thread, with a small cost-limited cache
/// so neighbours can be prefetched and flipping back and forth is instant.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, Box<LoadedImage>>()
    private let lock = NSLock()
    private var inflight: [URL: Task<LoadedImage?, Never>] = [:]

    init() { cache.totalCostLimit = 1_500_000_000 }

    func cached(_ url: URL) -> LoadedImage? { cache.object(forKey: url as NSURL)?.value }

    func load(_ url: URL) async -> LoadedImage? {
        if let c = cached(url) { return c }
        let task: Task<LoadedImage?, Never> = lock.withLock {
            if let t = inflight[url] { return t }
            let t = Task.detached(priority: .userInitiated) { [cache] () -> LoadedImage? in
                let r = await Self.decode(url)
                if let r {
                    cache.setObject(Box(r), forKey: url as NSURL, cost: Int(r.pixelSize.width * r.pixelSize.height * 4))
                }
                return r
            }
            inflight[url] = t
            return t
        }
        let result = await task.value
        lock.withLock { inflight[url] = nil }
        return result
    }

    func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil {
            Task.detached(priority: .utility) { _ = await self.load(url) }
        }
    }

    private static let animatedTypes: Set<String> = ["com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis"]

    static func decode(_ url: URL) async -> LoadedImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            let count = CGImageSourceGetCount(src)
            let type = CGImageSourceGetType(src) as String? ?? ""

            if count > 1, animatedTypes.contains(type), let img = NSImage(contentsOf: url),
               let rep = img.representations.first, rep.pixelsWide > 0 {
                let size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                img.size = size
                return LoadedImage(image: img, pixelSize: size, isAnimated: true)
            }

            // Pick the largest sub-image for icon-like containers (ico/icns), else the first one.
            var index = 0
            if count > 1, type.contains("ico") || type.contains("icns") {
                var best = 0
                for i in 0..<count {
                    let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                    let w = p?[kCGImagePropertyPixelWidth] as? Int ?? 0
                    if w > best { best = w; index = i }
                }
            }
            let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h) > 0 ? max(w, h) : 16384,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) {
                let size = CGSize(width: cg.width, height: cg.height)
                return LoadedImage(image: NSImage(cgImage: cg, size: size), pixelSize: size, isAnimated: false)
            }
        }
        // Vector formats (SVG) and anything else NSImage understands.
        if let img = NSImage(contentsOf: url), img.isValid, img.size.width > 0, img.size.height > 0 {
            var size = img.size
            if let rep = img.representations.first, rep.pixelsWide > 0 {
                size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                img.size = size
            }
            return LoadedImage(image: img, pixelSize: size, isAnimated: false)
        }
        // Formats only ffmpeg knows (QOI, JPEG XL on older systems, PCX…).
        if let png = await FFmpeg.convertImageToPNG(url),
           let src = CGImageSourceCreateWithURL(png as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let size = CGSize(width: cg.width, height: cg.height)
            return LoadedImage(image: NSImage(cgImage: cg, size: size), pixelSize: size, isAnimated: false)
        }
        return nil
    }
}
