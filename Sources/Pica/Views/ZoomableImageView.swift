import AppKit
import Observation
import SwiftUI

/// Bridges toolbar/keyboard zoom commands to the AppKit scroll view and reports the zoom level.
@MainActor @Observable
final class ZoomController {
    @ObservationIgnored weak var scrollView: ZoomScrollView?
    private(set) var percent = 100
    private(set) var isFit = true

    func zoomIn() { scrollView?.zoom(by: 1.25) }
    func zoomOut() { scrollView?.zoom(by: 0.8) }
    func fit() { scrollView?.fitToWindow() }
    func actualSize() { scrollView?.setZoom(1) }

    func update(percent: Int, fit: Bool) {
        DispatchQueue.main.async {
            if self.percent != percent { self.percent = percent }
            if self.isFit != fit { self.isFit = fit }
        }
    }
}

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let pixelSize: CGSize
    let controller: ZoomController

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(frame: .zero)
        view.controller = controller
        controller.scrollView = view
        view.setImage(image, pixelSize: pixelSize)
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        controller.scrollView = view
        view.controller = controller
        if view.image !== image { view.setImage(image, pixelSize: pixelSize) }
    }
}

/// Keeps the document centred when it's smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let frame = doc.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

final class ZoomScrollView: NSScrollView {
    let imageView = PanImageView()
    weak var controller: ZoomController?
    private(set) var image: NSImage?
    private(set) var fitMode = true
    private var pixelSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        allowsMagnification = true
        minMagnification = 0.01
        maxMagnification = 40
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.animates = true
        imageView.isEditable = false
        documentView = imageView
        imageView.onDoubleClick = { [weak self] p in self?.toggleZoom(at: p) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded),
            name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: pixelSize)
        fitMode = true
        applyFit()
    }

    private var fitMagnification: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        let avail = frame.size
        var m = min(avail.width / pixelSize.width, avail.height / pixelSize.height)
        if !Prefs.upscale { m = min(m, 1) }
        return max(m, minMagnification)
    }

    private func applyFit() {
        guard image != nil, frame.width > 1, frame.height > 1 else { return }
        magnification = fitMagnification
        report()
    }

    func fitToWindow() {
        fitMode = true
        applyFit()
    }

    func setZoom(_ m: CGFloat, centeredAt point: NSPoint? = nil) {
        guard image != nil else { return }
        fitMode = false
        let clamped = min(max(m, minMagnification), maxMagnification)
        let visible = contentView.bounds
        let center = point ?? NSPoint(x: visible.midX, y: visible.midY)
        setMagnification(clamped, centeredAt: center)
        report()
    }

    func zoom(by factor: CGFloat) { setZoom(magnification * factor) }

    private func toggleZoom(at point: NSPoint) {
        if fitMode || abs(magnification - fitMagnification) < 0.001 {
            setZoom(max(1, fitMagnification * 2), centeredAt: point)
        } else {
            fitToWindow()
        }
    }

    @objc private func liveMagnifyEnded() {
        fitMode = abs(magnification - fitMagnification) < 0.001
        report()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitMode { applyFit() }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            let p = imageView.convert(event.locationInWindow, from: nil)
            setZoom(magnification * exp(delta), centeredAt: p)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func report() {
        controller?.update(percent: Int((magnification * 100).rounded()), fit: fitMode)
    }
}

/// Image view that pans its scroll view on drag and reports double-clicks.
final class PanImageView: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?
    private var dragStart: NSPoint?
    private var originStart: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        dragStart = event.locationInWindow
        originStart = enclosingScrollView?.contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = originStart, let sv = enclosingScrollView else { return }
        let mag = sv.magnification
        let dx = (event.locationInWindow.x - start.x) / mag
        let dy = (event.locationInWindow.y - start.y) / mag
        let clip = sv.contentView
        let proposed = NSRect(origin: NSPoint(x: origin.x - dx, y: origin.y - dy), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        sv.reflectScrolledClipView(clip)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        originStart = nil
        NSCursor.arrow.set()
    }
}
