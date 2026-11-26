import SwiftUI

struct VideoStage: View {
    let item: MediaItem
    @Bindable var controller: VideoPlayerController

    /// How long the pointer must be still (and off the controls) before the controls fade.
    static let idleDelay: TimeInterval = 2.5

    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var lastMouse: CGPoint?
    @State private var controlsFrame: CGRect = .zero
    @State private var window: NSWindow?

    var body: some View {
        ZStack {
            PlayerSurface(player: controller.player)
                .opacity(controller.isReady ? 1 : 0)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2)
                        .onEnded {
                            // In the full-screen overlay there's nothing to toggle.
                            if !ViewerOverlay.shared.isVisible { KeyboardRouter.shared.mainWindow?.toggleFullScreen(nil) }
                        }
                        .exclusively(before: TapGesture().onEnded { controller.togglePlay() })
                )

            statusOverlay
        }
        .overlay(alignment: .topLeading) {
            if controller.isScrubbing {
                ScrubHUD(controller: controller)
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: controller.isScrubbing)
        .overlay(alignment: .bottom) {
            VideoControls(controller: controller)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { controlsFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in controlsFrame = f }
                })
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .animation(.easeInOut(duration: 0.35), value: showControls)
                .disabled(!controller.isReady)
        }
        .background(WindowAccessor { window = $0 })
        .onChange(of: controller.isPlaying) { noteActivity() }
        .onChange(of: controller.isScrubbing) { noteActivity() }
        .task {
            // Watch the real pointer position rather than SwiftUI hover callbacks, which also
            // fire when the view redraws (the time label updates many times a second).
            noteActivity()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                checkPointer()
            }
        }
    }

    private var showControls: Bool {
        controlsVisible || !controller.isPlaying || controller.isScrubbing
    }

    private func noteActivity() {
        lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    private func checkPointer() {
        let mouse = NSEvent.mouseLocation
        defer { lastMouse = mouse }
        let moved = lastMouse.map { hypot($0.x - mouse.x, $0.y - mouse.y) > 2 } ?? false
        if moved || isOverControls(mouse) {
            noteActivity()
            return
        }
        guard controlsVisible, controller.isPlaying, !controller.isScrubbing,
              Date().timeIntervalSince(lastActivity) > Self.idleDelay else { return }
        controlsVisible = false
        if let window, window.isKeyWindow, window.frame.contains(mouse) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Whether the pointer (in screen coordinates) is over the control bar.
    private func isOverControls(_ screenPoint: CGPoint) -> Bool {
        guard let window, let content = window.contentView, controlsFrame.width > 0 else { return false }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        var p = content.convert(inWindow, from: nil)
        if !content.isFlipped { p.y = content.bounds.height - p.y }   // SwiftUI's global space is top-down
        return controlsFrame.insetBy(dx: -8, dy: -8).contains(p)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.phase {
        case .idle, .loading:
            ProgressView().controlSize(.regular).tint(.white)
        case .converting(let p):
            VStack(spacing: 10) {
                Text("Preparing \(item.ext.uppercased()) for playback…")
                    .font(.headline)
                ProgressView(value: p)
                    .frame(width: 240)
                Text(p > 0 ? "\(Int(p * 100))% · kept until Pica quits" : "Starting ffmpeg…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Play This Video", systemImage: "film")
            } description: {
                Text(message)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 460)
        case .ready:
            EmptyView()
        }
    }

}

/// Small corner notice while scrubbing: direction, speed and position.
struct ScrubHUD: View {
    let controller: VideoPlayerController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.scrubDirection < 0 ? "backward.fill" : "forward.fill")
                .font(.system(size: 12, weight: .bold))
            Text(speedText)
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
            Text("\(Format.duration(controller.currentTime)) / \(Format.duration(controller.duration))")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
        .allowsHitTesting(false)
    }

    private var speedText: String {
        let s = controller.scrubSpeed
        return s >= 10 || s == s.rounded() ? "\(Int(s.rounded()))×" : String(format: "%.1f×", s)
    }
}

struct VideoControls: View {
    @Bindable var controller: VideoPlayerController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(Format.duration(controller.currentTime))
                    .monospacedDigit()
                    .frame(minWidth: 46, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { controller.currentTime },
                        set: { controller.userSeek(to: $0) }
                    ),
                    in: 0...max(controller.duration, 0.01),
                    onEditingChanged: { editing in
                        editing ? controller.beginUserSeek() : controller.endUserSeek()
                    }
                )
                .controlSize(.small)
                Text(Format.duration(controller.duration))
                    .monospacedDigit()
                    .frame(minWidth: 46, alignment: .leading)
            }
            .font(.caption)

            HStack(spacing: 6) {
                HoldButton(systemImage: "backward.fill", help: "Hold to rewind — tap to jump back 5 s (J, or hold ←)",
                           onPress: { controller.pressScrub(-1) }, onRelease: { controller.releaseScrub() })
                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play / pause (Space or K)")
                HoldButton(systemImage: "forward.fill", help: "Hold to fast-forward — tap to jump ahead 5 s (L, or hold →)",
                           onPress: { controller.pressScrub(1) }, onRelease: { controller.releaseScrub() })

                Divider().frame(height: 18).padding(.horizontal, 4)

                Button { controller.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help("Previous frame (,)")
                Button { controller.stepFrame(1) } label: { Image(systemName: "forward.frame.fill").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help("Next frame (.)")

                Spacer()

                if controller.wasConverted {
                    Text("via ffmpeg")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .help("This format isn't supported by macOS, so it was converted with ffmpeg")
                }

                Menu {
                    ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3] as [Float], id: \.self) { r in
                        Button {
                            controller.rate = r
                        } label: {
                            if r == controller.rate { Label(rateLabel(r), systemImage: "checkmark") } else { Text(rateLabel(r)) }
                        }
                    }
                } label: {
                    Text(rateLabel(controller.rate)).monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed")

                Toggle(isOn: $controller.loop) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(controller.loop ? Color.accentColor : .white)
                .help("Loop")

                Button { controller.toggleMute() } label: {
                    Image(systemName: controller.isMuted || controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .help("Mute (M)")
                Slider(value: $controller.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 80)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 820)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func rateLabel(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
    }
}
