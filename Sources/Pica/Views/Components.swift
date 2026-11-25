import AppKit
import AVFoundation
import SwiftUI

/// Reports the hosting NSWindow (used to scope keyboard handling to the main window).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let v = WindowTrackingView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {}

    final class WindowTrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }
}

/// AVPlayerLayer-backed view.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView { PlayerLayerView(player: player) }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        init(player: AVPlayer) {
            super.init(frame: .zero)
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.clear.cgColor
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func makeBackingLayer() -> CALayer { playerLayer }
    }
}

/// A button that reports press and release separately (for hold-to-scrub).
struct HoldButton: View {
    let systemImage: String
    let help: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 36, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(pressed ? 0.28 : 0.001))
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
            .help(help)
    }
}

/// Small notice in the bottom-right corner, kept off the photo: above the status bar in
/// the grid; in the viewer it sits at the right end of the filmstrip row (or, with the
/// filmstrip hidden, in the corner, above the video controls), left of the info panel.
struct ToastView: View {
    @Environment(Library.self) private var library

    private var bottomInset: CGFloat {
        guard library.viewerOpen else { return 34 }
        if library.showFilmstrip { return 25 }   // vertically centred in the 84-pt filmstrip row
        return library.currentItem?.kind == .video ? 110 : 14
    }

    private var trailingInset: CGFloat {
        library.viewerOpen && library.showInfo ? 290 + 14 : 14
    }

    var body: some View {
        if let toast = library.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? .yellow : .green)
                Text(toast.message)
                    .lineLimit(2)
                if toast.canUndo {
                    Button("Undo") { library.undo() }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .frame(maxWidth: 420, alignment: .trailing)
            .padding(.trailing, trailingInset)
            .padding(.bottom, bottomInset)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(toast.canUndo ? 5 : 3.5))
                if library.toast?.id == toast.id {
                    withAnimation(.easeOut(duration: 0.2)) { library.toast = nil }
                }
            }
        }
    }
}

/// Thumbnail image for a media item, loaded asynchronously and cached.
struct ThumbnailImage: View {
    let item: MediaItem
    var contentMode: ContentMode = .fit
    @State private var thumb: Thumbnail?
    @State private var failed = false

    init(item: MediaItem, contentMode: ContentMode = .fit) {
        self.item = item
        self.contentMode = contentMode
        _thumb = State(initialValue: ThumbnailService.shared.cached(item.url))
    }

    var duration: Double? { thumb?.duration }

    var body: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: item.kind == .video ? "film" : "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: item.url) {
            if thumb == nil || ThumbnailService.shared.cached(item.url) == nil {
                let t = await ThumbnailService.shared.thumbnail(for: item)
                if Task.isCancelled { return }
                thumb = t
                failed = t == nil
            }
        }
    }
}

/// Wraps NSVisualEffectView.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.material = material
        v.blendingMode = blending
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Backdrop of the viewer: dimmed desktop, blurred desktop, or black.
struct ViewerBackdrop: View {
    @AppStorage(Prefs.Key.viewerBackground) private var style = ViewerBackground.translucent.rawValue
    @AppStorage(Prefs.Key.viewerOpacity) private var opacity = 0.78

    var body: some View {
        switch ViewerBackground(rawValue: style) ?? .translucent {
        case .black:
            Color.black
        case .translucent:
            Color.black.opacity(opacity)
        case .blurred:
            ZStack {
                VisualEffectBackground(material: .fullScreenUI)
                Color.black.opacity(opacity * 0.6)
            }
        }
    }
}
