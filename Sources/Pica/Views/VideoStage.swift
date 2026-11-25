import SwiftUI

struct VideoStage: View {
    let item: MediaItem
    @Bindable var controller: VideoPlayerController
    @State private var controlsVisible = true
    @State private var hoveringControls = false
    @State private var hideTask: Task<Void, Never>?

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

            if controller.isScrubbing {
                ScrubHUD(controller: controller)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            VideoControls(controller: controller)
                .onHover { hoveringControls = $0; poke() }
                .opacity(controlsVisible || !controller.isPlaying || controller.isScrubbing ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)
                .disabled(!controller.isReady)
        }
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        .onChange(of: controller.isPlaying) { poke() }
        .onAppear { poke() }
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
                Text(p > 0 ? "\(Int(p * 100))% · converted once, then cached" : "Starting ffmpeg…")
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

    private func poke() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, controller.isPlaying, !hoveringControls, !controller.isScrubbing else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// Big centred indicator while scrubbing: direction, speed and position.
struct ScrubHUD: View {
    let controller: VideoPlayerController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: controller.scrubDirection < 0 ? "backward.fill" : "forward.fill")
                Text(speedText).monospacedDigit()
            }
            .font(.system(size: 30, weight: .bold))
            Text("\(Format.duration(controller.currentTime)) / \(Format.duration(controller.duration))")
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
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
