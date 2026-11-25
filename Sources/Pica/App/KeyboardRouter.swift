import AppKit

/// App-wide keyboard handling for the main window. Uses a local event monitor so it sees
/// both key-down and key-up (needed for hold-to-scrub) regardless of which view has focus.
@MainActor
final class KeyboardRouter {
    static let shared = KeyboardRouter()

    weak var mainWindow: NSWindow?
    /// The full-screen viewer overlay, while it's shown.
    weak var viewerWindow: NSWindow?

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    // ← / → on a video: tap = previous/next item, hold = scrub.
    private var arrowKey: UInt16?
    private var arrowWork: DispatchWorkItem?
    private var arrowScrubbing = false
    // J / L: tap = ±5 s, hold = scrub.
    private var scrubKey: UInt16?

    static let arrowHoldDelay: TimeInterval = 0.28

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { KeyboardRouter.shared.handle(event) ? nil : event }
        }
        // If the window loses focus mid-hold we'd never see the key-up.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { KeyboardRouter.shared.cancelHolds() }
        }
    }

    func cancelHolds() {
        arrowWork?.cancel()
        arrowWork = nil
        arrowKey = nil
        if arrowScrubbing { Library.shared.video.endScrub() }
        arrowScrubbing = false
        if scrubKey != nil { Library.shared.video.endScrub() }
        scrubKey = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let window = e.window, window === mainWindow || window === viewerWindow,
              window.attachedSheet == nil else { return false }
        let lib = Library.shared

        if e.type == .keyUp { return handleKeyUp(e, lib) }

        let responder = window.firstResponder
        if let tv = responder as? NSTextView, tv.isEditable { return false }

        let mods = e.modifierFlags
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            if mods.contains(.command), !mods.contains(.control), !mods.contains(.option),
               e.charactersIgnoringModifiers?.lowercased() == "a", !lib.viewerOpen {
                lib.selectAll()
                return true
            }
            return false
        }

        // Let the sidebar handle its own arrow keys; Return/Tab hands focus to the grid.
        if responder is NSTableView, !lib.viewerOpen {
            if e.keyCode == KeyCode.returnKey || e.keyCode == KeyCode.tab {
                window.makeFirstResponder(nil)
                return true
            }
            return false
        }

        return lib.viewerOpen ? handleViewer(e, lib, window: window) : handleGrid(e, lib, shift: mods.contains(.shift))
    }

    private func handleGrid(_ e: NSEvent, _ lib: Library, shift: Bool) -> Bool {
        let cols = max(1, lib.gridColumns)
        switch e.keyCode {
        case KeyCode.left: lib.moveFocus(by: -1, extend: shift)
        case KeyCode.right: lib.moveFocus(by: 1, extend: shift)
        case KeyCode.up: lib.moveFocus(by: -cols, extend: shift)
        case KeyCode.down: lib.moveFocus(by: cols, extend: shift)
        case KeyCode.pageUp: lib.moveFocus(by: -cols * 4, extend: shift)
        case KeyCode.pageDown: lib.moveFocus(by: cols * 4, extend: shift)
        case KeyCode.home: lib.moveFocus(by: -Int.max / 2, extend: shift)
        case KeyCode.end: lib.moveFocus(by: Int.max / 2, extend: shift)
        case KeyCode.returnKey, KeyCode.enter, KeyCode.space: lib.openViewer()
        case KeyCode.delete, KeyCode.forwardDelete: lib.deleteTargets()
        case KeyCode.escape: lib.clearSelection()
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "f": lib.toggleFavoriteTargets()
            case "r": lib.restoreTargets()
            default: return false
            }
        }
        return true
    }

    private func handleViewer(_ e: NSEvent, _ lib: Library, window: NSWindow) -> Bool {
        let video = lib.video
        let isVideo = lib.currentItem?.kind == .video
        let canScrub = isVideo && video.isReady

        switch e.keyCode {
        case KeyCode.left, KeyCode.right:
            let dir = e.keyCode == KeyCode.left ? -1 : 1
            if canScrub {
                if e.isARepeat || arrowKey != nil { return true }
                arrowKey = e.keyCode
                arrowScrubbing = false
                let key = e.keyCode
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.arrowKey == key else { return }
                    self.arrowScrubbing = true
                    video.beginScrub(dir)
                }
                arrowWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrowHoldDelay, execute: work)
            } else {
                lib.step(dir)
            }
        case KeyCode.down, KeyCode.pageDown: lib.step(1)
        case KeyCode.up, KeyCode.pageUp: lib.step(-1)
        case KeyCode.home: lib.goToFirst()
        case KeyCode.end: lib.goToLast()
        case KeyCode.escape:
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { lib.closeViewer() }
        case KeyCode.returnKey, KeyCode.enter: lib.closeViewer()
        case KeyCode.space:
            if isVideo { video.togglePlay() } else { lib.step(1) }
        case KeyCode.delete, KeyCode.forwardDelete: lib.deleteTargets()
        default:
            guard let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
            switch ch {
            case "f": lib.toggleFavoriteTargets()
            case "r": lib.restoreTargets()
            case "i": lib.showInfo.toggle()
            case "t": lib.showFilmstrip.toggle()
            case "j", "l":
                guard canScrub else { return true }
                if !e.isARepeat && scrubKey == nil {
                    scrubKey = e.keyCode
                    video.pressScrub(ch == "j" ? -1 : 1)
                }
            case "k": if isVideo { video.togglePlay() }
            case ",": if isVideo { video.stepFrame(-1) }
            case ".": if isVideo { video.stepFrame(1) }
            case "m": if isVideo { video.toggleMute() }
            case "0": lib.zoom.fit()
            case "1": lib.zoom.actualSize()
            case "=", "+": lib.zoom.zoomIn()
            case "-", "_": lib.zoom.zoomOut()
            default: return false
            }
        }
        return true
    }

    private func handleKeyUp(_ e: NSEvent, _ lib: Library) -> Bool {
        if let key = arrowKey, e.keyCode == key {
            arrowKey = nil
            arrowWork?.cancel()
            arrowWork = nil
            if arrowScrubbing {
                arrowScrubbing = false
                lib.video.endScrub()
            } else {
                lib.step(key == KeyCode.left ? -1 : 1)
            }
            return true
        }
        if let key = scrubKey, e.keyCode == key {
            scrubKey = nil
            lib.video.releaseScrub()
            return true
        }
        return false
    }
}

enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let enter: UInt16 = 76
    static let home: UInt16 = 115
    static let pageUp: UInt16 = 116
    static let forwardDelete: UInt16 = 117
    static let end: UInt16 = 119
    static let pageDown: UInt16 = 121
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}
