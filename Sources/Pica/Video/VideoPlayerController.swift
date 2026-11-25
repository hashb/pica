import AVFoundation
import Observation
import QuartzCore

/// Owns the single AVPlayer used by the viewer: loading (with ffmpeg fallback), playback,
/// coalesced seeking, and hold-to-scrub with an accelerating speed.
@MainActor @Observable
final class VideoPlayerController {
    enum Phase: Equatable {
        case idle
        case loading
        case converting(Double)
        case ready
        case failed(String)
    }

    let player = AVPlayer()

    private(set) var phase: Phase = .idle
    private(set) var currentURL: URL?
    private(set) var isPlaying = false
    var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isScrubbing = false
    private(set) var scrubDirection = 0
    private(set) var scrubSpeed: Double = 0
    private(set) var wasConverted = false

    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }
    var isMuted: Bool { didSet { player.isMuted = isMuted; Prefs.d.set(isMuted, forKey: Prefs.Key.muted) } }
    var volume: Float { didSet { player.volume = volume; Prefs.d.set(volume, forKey: Prefs.Key.volume) } }
    var loop: Bool { didSet { Prefs.d.set(loop, forKey: Prefs.Key.loop) } }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    // Scrub state
    @ObservationIgnored private var scrubTimer: Timer?
    @ObservationIgnored private var scrubStart: CFTimeInterval = 0
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var scrubTarget: Double = 0
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var pressTime: CFTimeInterval = 0
    @ObservationIgnored private var pressOrigin: Double = 0

    // Seek coalescing
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var pendingSeek: (time: Double, tolerance: Double)?
    @ObservationIgnored private var userSeeking = false
    @ObservationIgnored private var resumeAfterUserSeek = false

    /// A short press shorter than this is a "tap": jump by `tapJump` seconds instead of scrubbing.
    static let tapThreshold: CFTimeInterval = 0.22
    static let tapJump: Double = 5

    init() {
        Prefs.registerDefaults()
        isMuted = Prefs.d.bool(forKey: Prefs.Key.muted)
        volume = Prefs.d.float(forKey: Prefs.Key.volume)
        loop = Prefs.loop
        player.isMuted = isMuted
        player.volume = volume
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.userSeeking, !self.seekInFlight else { return }
                let s = time.seconds
                if s.isFinite { self.currentTime = s }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                if self.loop && !self.isScrubbing {
                    self.player.seek(to: .zero)
                    self.player.playImmediately(atRate: self.rate)
                }
            }
        }
    }

    var isReady: Bool { phase == .ready }

    // MARK: Loading

    func load(_ url: URL, autoplay: Bool) {
        guard url != currentURL else { return }
        stop()
        currentURL = url
        phase = .loading
        loadTask = Task { [weak self] in await self?.prepare(url, autoplay: autoplay) }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        cancelScrub()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        phase = .idle
        duration = 0
        currentTime = 0
        wasConverted = false
        pendingSeek = nil
        userSeeking = false
    }

    private func isCurrent(_ url: URL) -> Bool { !Task.isCancelled && currentURL == url }

    private func prepare(_ url: URL, autoplay: Bool) async {
        let asset = AVURLAsset(url: url)
        var convertedURL: URL?
        if await !Self.canPlayNatively(asset) {
            guard isCurrent(url) else { return }
            convertedURL = await convert(url)
            guard convertedURL != nil else { return }
        }
        guard isCurrent(url) else { return }

        var item = AVPlayerItem(asset: convertedURL.map { AVURLAsset(url: $0) } ?? asset)
        player.replaceCurrentItem(with: item)
        var ready = await waitForReady(item)
        guard isCurrent(url) else { return }

        if !ready && convertedURL == nil {
            // AVFoundation claimed it could play this but failed; fall back to ffmpeg.
            player.replaceCurrentItem(with: nil)
            guard let converted = await convert(url), isCurrent(url) else { return }
            item = AVPlayerItem(asset: AVURLAsset(url: converted))
            player.replaceCurrentItem(with: item)
            ready = await waitForReady(item)
            guard isCurrent(url) else { return }
        }
        guard ready else {
            phase = .failed(item.error?.localizedDescription ?? "This video could not be played.")
            return
        }
        let d = (try? await item.asset.load(.duration))?.seconds ?? 0
        guard isCurrent(url) else { return }
        duration = d.isFinite ? d : 0
        currentTime = 0
        phase = .ready
        if autoplay { player.playImmediately(atRate: rate) }
    }

    private func convert(_ url: URL) async -> URL? {
        guard FFmpeg.isAvailable else {
            phase = .failed("macOS can't play this format on its own. Install ffmpeg (for example with Homebrew: brew install ffmpeg) and Pica will convert it automatically.")
            return nil
        }
        phase = .converting(0)
        do {
            let out = try await FFmpeg.makePlayable(url) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.currentURL == url, case .converting = self.phase else { return }
                    self.phase = .converting(p)
                }
            }
            wasConverted = true
            return out
        } catch {
            if isCurrent(url) { phase = .failed("Couldn't convert this video: \(error.localizedDescription)") }
            return nil
        }
    }

    static func canPlayNatively(_ asset: AVURLAsset) async -> Bool {
        do {
            guard try await asset.load(.isPlayable) else { return false }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return true }
            return try await track.load(.isPlayable)
        } catch {
            return false
        }
    }

    private func waitForReady(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<400 {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: break
            }
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return false }
        }
        return false
    }

    // MARK: Playback

    func togglePlay() {
        guard isReady else { return }
        if player.rate != 0 || player.timeControlStatus != .paused {
            player.pause()
        } else {
            if duration > 0 && currentTime >= duration - 0.05 { seek(to: 0) }
            player.playImmediately(atRate: rate)
        }
    }

    func toggleMute() { isMuted.toggle() }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    func stepFrame(_ count: Int) {
        guard isReady else { return }
        player.pause()
        player.currentItem?.step(byCount: count)
    }

    /// Seeks, coalescing requests so only the latest pending target is sent after the current seek finishes.
    func seek(to time: Double, tolerance: Double = 0) {
        guard isReady else { return }
        let t = max(0, min(time, duration > 0 ? duration : time))
        currentTime = t
        pendingSeek = (t, tolerance)
        if !seekInFlight { runPendingSeek() }
    }

    private func runPendingSeek() {
        guard let next = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        let tol = next.tolerance > 0 ? CMTime(seconds: next.tolerance, preferredTimescale: 600) : .zero
        player.seek(to: CMTime(seconds: next.time, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if self.pendingSeek != nil { self.runPendingSeek() }
            }
        }
    }

    // Timeline slider dragging
    func beginUserSeek() {
        guard isReady, !userSeeking else { return }
        userSeeking = true
        resumeAfterUserSeek = player.rate != 0
        player.pause()
    }

    func userSeek(to t: Double) { seek(to: t, tolerance: 0.1) }

    func endUserSeek() {
        guard userSeeking else { return }
        userSeeking = false
        seek(to: currentTime)
        if resumeAfterUserSeek { player.playImmediately(atRate: rate) }
    }

    // MARK: Hold-to-scrub

    /// Press: start scrubbing at once. If released quickly it becomes a ±5 s jump instead.
    func pressScrub(_ direction: Int) {
        guard isReady else { return }
        pressTime = CACurrentMediaTime()
        pressOrigin = currentTime
        beginScrub(direction)
    }

    func releaseScrub() {
        guard isScrubbing else { return }
        if CACurrentMediaTime() - pressTime < Self.tapThreshold {
            let resume = resumeAfterScrub
            let target = pressOrigin + Double(scrubDirection) * Self.tapJump
            cancelScrub()
            seek(to: target)
            if resume { player.playImmediately(atRate: rate) }
        } else {
            endScrub()
        }
    }

    func beginScrub(_ direction: Int) {
        guard isReady, duration > 0 else { return }
        let resume = isScrubbing ? resumeAfterScrub : (player.rate != 0)
        cancelScrub()
        resumeAfterScrub = resume
        player.pause()
        isScrubbing = true
        scrubDirection = direction
        scrubSpeed = Prefs.scrubBaseSpeed
        scrubStart = CACurrentMediaTime()
        lastTick = scrubStart
        scrubTarget = currentTime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrubTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrubTimer = timer
    }

    func endScrub() {
        guard isScrubbing else { return }
        let resume = resumeAfterScrub
        let target = scrubTarget
        cancelScrub()
        seek(to: target)
        if resume && target < duration - 0.05 { player.playImmediately(atRate: rate) }
    }

    private func cancelScrub() {
        scrubTimer?.invalidate()
        scrubTimer = nil
        if isScrubbing { isScrubbing = false }
        scrubDirection = 0
        scrubSpeed = 0
    }

    /// Speed doubles the longer the button is held: base, 2×, 4×… up to 128× base,
    /// but never so fast that a short clip flies past in under ~3 seconds.
    nonisolated static func scrubSpeed(heldFor held: Double, base: Double, duration: Double) -> Double {
        let thresholds: [Double] = [0, 0.7, 1.4, 2.2, 3.2, 4.5, 6, 8]
        let level = thresholds.lastIndex { held >= $0 } ?? 0
        let speed = base * pow(2, Double(level))
        return min(speed, max(base, duration / 3))
    }

    private func scrubTick() {
        guard isScrubbing else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        let speed = Self.scrubSpeed(heldFor: now - scrubStart, base: Prefs.scrubBaseSpeed, duration: duration)
        if speed != scrubSpeed { scrubSpeed = speed }
        scrubTarget = max(0, min(duration, scrubTarget + Double(scrubDirection) * speed * dt))
        currentTime = scrubTarget
        // Exact frames at low speed; allow keyframe-ish snapping when moving fast so the picture keeps up.
        pendingSeek = (scrubTarget, speed <= 4 ? 0 : min(1.0, speed / 30))
        if !seekInFlight { runPendingSeek() }
    }
}
