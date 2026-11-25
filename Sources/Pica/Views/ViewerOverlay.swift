import AppKit
import SwiftUI

/// Borderless window that can take keyboard focus.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the viewer Picasa-style: one see-through borderless window covering the whole screen,
/// so everything behind it is dimmed (or blurred) around the photo. The menu bar and Dock
/// hide while it's up.
@MainActor
final class ViewerOverlay {
    static let shared = ViewerOverlay()

    private(set) var window: OverlayWindow?
    private weak var returnWindow: NSWindow?
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { window?.isVisible == true }

    func show(library: Library, over parent: NSWindow?) {
        hideWork?.cancel()
        hideWork = nil
        let screen = parent?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        returnWindow = parent

        let w = window ?? makeWindow()
        window = w
        w.contentView = NSHostingView(
            rootView: ViewerView(isOverlay: true)
                .environment(library)
                .preferredColorScheme(.dark)
        )
        w.setFrame(screen.frame, display: false)
        KeyboardRouter.shared.viewerWindow = w

        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        if !w.isVisible { w.alphaValue = 0 }
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        NSApp.presentationOptions = []
        KeyboardRouter.shared.cancelHolds()
        returnWindow?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let w = self.window else { return }
            w.orderOut(nil)
            // Drop the SwiftUI tree so nothing keeps rendering while hidden.
            w.contentView = nil
            KeyboardRouter.shared.viewerWindow = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func makeWindow() -> OverlayWindow {
        let w = OverlayWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
        // If you switch to another app the overlay steps aside, and comes back when you return.
        w.hidesOnDeactivate = true
        // See-through: the backdrop view decides how much of the screen behind shows.
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.acceptsMouseMovedEvents = true
        w.animationBehavior = .none
        return w
    }
}
