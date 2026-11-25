import SwiftUI

struct ViewerView: View {
    /// Shown in the full-screen overlay window: uses its own top bar instead of the window toolbar.
    var isOverlay = false

    @Environment(Library.self) private var library
    @State private var hoveringEdge: Int = 0

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            if isOverlay {
                OverlayTopBar()
            }
            ZStack {
                Color.clear
                if let item = library.currentItem {
                    switch item.kind {
                    case .image: ImageStage(item: item, zoom: library.zoom)
                    case .video: VideoStage(item: item, controller: library.video)
                    }
                }
                edgeNavigation
            }
            .overlay(alignment: .trailing) {
                if library.showInfo, let item = library.currentItem {
                    InfoPanel(item: item)
                        .frame(width: 290)
                        .transition(.move(edge: .trailing))
                }
            }
            .clipped()

            if library.showFilmstrip {
                FilmstripView()
                    .frame(height: 84)
                    .transition(.move(edge: .bottom))
            }
        }
        .background(ViewerBackdrop().ignoresSafeArea())
        .overlay(alignment: .top) {
            if isOverlay {
                ToastView()
                    .padding(.top, 40)
                    .animation(.spring(duration: 0.3), value: library.toast)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: library.showInfo)
        .animation(.easeInOut(duration: 0.18), value: library.showFilmstrip)
        .modifier(WindowToolbar(enabled: !isOverlay) { viewerToolbar })
    }

    /// Hover zones on the left/right edges with previous/next buttons.
    private var edgeNavigation: some View {
        HStack {
            edgeButton(-1, systemImage: "chevron.left")
            Spacer()
            edgeButton(1, systemImage: "chevron.right")
        }
        .padding(.bottom, library.currentItem?.kind == .video ? 90 : 0)
    }

    private func edgeButton(_ dir: Int, systemImage: String) -> some View {
        let enabled = dir < 0 ? (library.currentIndex ?? 0) > 0 : (library.currentIndex ?? 0) < library.items.count - 1
        return Button {
            library.step(dir)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 64)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(hoveringEdge == dir && enabled ? 1 : 0)
        .frame(width: 90)
        .frame(maxHeight: 240)
        .contentShape(Rectangle())
        .onHover { hoveringEdge = $0 ? dir : 0 }
        .padding(.horizontal, 6)
        .disabled(!enabled)
    }

    @ToolbarContentBuilder
    private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                library.closeViewer()
            } label: {
                Label("Thumbnails", systemImage: "square.grid.2x2")
            }
            .help("Back to thumbnails (Esc)")
        }
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(library.currentItem?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let i = library.currentIndex {
                    Text("\(i + 1) of \(library.items.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 360, alignment: .leading)
            .padding(.leading, 4)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { library.step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled((library.currentIndex ?? 0) == 0)
                    .help("Previous (←)")
                Button { library.step(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .disabled((library.currentIndex ?? 0) >= library.items.count - 1)
                    .help("Next (→)")
            }

            if library.currentItem?.kind == .image {
                ControlGroup {
                    Button { library.zoom.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        .help("Zoom out (−)")
                    Button { library.zoom.isFit ? library.zoom.actualSize() : library.zoom.fit() } label: {
                        Text(library.zoom.isFit ? "Fit" : "\(library.zoom.percent)%")
                            .monospacedDigit()
                            .frame(minWidth: 44)
                    }
                    .help("Toggle fit / actual size (0 / 1)")
                    Button { library.zoom.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                        .help("Zoom in (+)")
                }
            }

            if let item = library.currentItem {
                if library.canRestore(item.url) {
                    Button { library.restoreTargets() } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .help("Restore to original location (R)")
                }
                Button { library.toggleFavoriteTargets() } label: {
                    Label("Favorite", systemImage: library.isFavorite(item.url) ? "star.fill" : "star")
                        .foregroundStyle(library.isFavorite(item.url) ? .yellow : .primary)
                }
                .help(library.isFavorite(item.url) ? "Remove from Favorites (F)" : "Move to Favorites (F)")
                Button { library.deleteTargets() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help(library.isInDeleted(item.url) ? "Move to the macOS Trash (⌫)" : "Move to the Deleted folder (⌫)")
            }

            Button { library.showInfo.toggle() } label: {
                Label("Info", systemImage: library.showInfo ? "info.circle.fill" : "info.circle")
            }
            .help("Show info (I)")
            Button { library.showFilmstrip.toggle() } label: {
                Label("Filmstrip", systemImage: "film.stack")
            }
            .help("Show filmstrip (T)")
        }
    }
}

struct ImageStage: View {
    let item: MediaItem
    let zoom: ZoomController
    @State private var loaded: LoadedImage?
    @State private var loadedURL: URL?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let loaded, loadedURL == item.url {
                ZoomableImageView(image: loaded.image, pixelSize: loaded.pixelSize, controller: zoom)
            } else if failed {
                ContentUnavailableView("Can't Open This Image", systemImage: "photo.badge.exclamationmark",
                                       description: Text(item.name))
                    .foregroundStyle(.white)
            } else {
                // Show the thumbnail scaled up while the full image decodes.
                if let thumb = ThumbnailService.shared.cached(item.url) {
                    Image(nsImage: thumb.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                }
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .task(id: item.url) {
            failed = false
            if let c = ImageLoader.shared.cached(item.url) {
                loaded = c
                loadedURL = item.url
                return
            }
            let result = await ImageLoader.shared.load(item.url)
            if Task.isCancelled { return }
            loaded = result
            loadedURL = item.url
            failed = result == nil
        }
    }
}

struct FilmstripView: View {
    @Environment(Library.self) private var library

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(library.items) { item in
                        let current = item.url == library.focused
                        ThumbnailImage(item: item, contentMode: .fill)
                            .frame(width: 66, height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(current ? Color.accentColor : .white.opacity(0.08), lineWidth: current ? 3 : 1)
                            )
                            .overlay(alignment: .bottomLeading) {
                                if item.kind == .video {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(.black.opacity(0.6), in: Circle())
                                        .padding(4)
                                }
                            }
                            .opacity(current ? 1 : 0.75)
                            .id(item.url)
                            .contentShape(Rectangle())
                            .onTapGesture { library.focus(item.url) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .background(Color.black.opacity(0.35))
            .onAppear {
                if let f = library.focused { proxy.scrollTo(f, anchor: .center) }
            }
            .onChange(of: library.focused) { _, f in
                if let f { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f, anchor: .center) } }
            }
        }
    }
}

struct InfoPanel: View {
    let item: MediaItem
    @State private var rows: [InfoRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Info").font(.headline)
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.key).font(.caption).foregroundStyle(.secondary)
                        Text(row.value).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
        .task(id: item.url) {
            rows = await MetadataLoader.load(item)
        }
    }
}

/// Applies the window toolbar only when the viewer is inside the main window.
private struct WindowToolbar<T: ToolbarContent>: ViewModifier {
    let enabled: Bool
    @ToolbarContentBuilder let toolbar: () -> T

    func body(content: Content) -> some View {
        if enabled {
            content.toolbar(content: toolbar)
        } else {
            content
        }
    }
}

/// Controls for the full-screen overlay: name on the left, actions in the middle, close on the right.
struct OverlayTopBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(library.currentItem?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let i = library.currentIndex {
                    Text("\(i + 1) of \(library.items.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.4), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))

            HStack {
                Spacer()
                OverlayButton(systemImage: "xmark", help: "Close (Esc)") { library.closeViewer() }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            OverlayButton(systemImage: "chevron.left", help: "Previous (←)") { library.step(-1) }
                .disabled((library.currentIndex ?? 0) == 0)
            OverlayButton(systemImage: "chevron.right", help: "Next (→)") { library.step(1) }
                .disabled((library.currentIndex ?? 0) >= library.items.count - 1)

            if library.currentItem?.kind == .image {
                divider
                OverlayButton(systemImage: "minus.magnifyingglass", help: "Zoom out (−)") { library.zoom.zoomOut() }
                Button {
                    library.zoom.isFit ? library.zoom.actualSize() : library.zoom.fit()
                } label: {
                    Text(library.zoom.isFit ? "Fit" : "\(library.zoom.percent)%")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .frame(minWidth: 46, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle fit / actual size (0 / 1)")
                OverlayButton(systemImage: "plus.magnifyingglass", help: "Zoom in (+)") { library.zoom.zoomIn() }
            }

            if let item = library.currentItem {
                divider
                let fav = library.isFavorite(item.url)
                OverlayButton(systemImage: fav ? "star.fill" : "star", tint: fav ? .yellow : nil,
                              help: fav ? "Remove from Favorites (F)" : "Move to Favorites (F)") {
                    library.toggleFavoriteTargets()
                }
                OverlayButton(systemImage: "trash",
                              help: library.isInDeleted(item.url) ? "Move to the macOS Trash (⌫)" : "Move to the Deleted folder (⌫)") {
                    library.deleteTargets()
                }
                if library.canRestore(item.url) {
                    OverlayButton(systemImage: "arrow.uturn.backward", help: "Restore to original location (R)") {
                        library.restoreTargets()
                    }
                }
            }

            divider
            OverlayButton(systemImage: library.showInfo ? "info.circle.fill" : "info.circle", help: "Info (I)") {
                library.showInfo.toggle()
            }
            OverlayButton(systemImage: "film.stack", help: "Filmstrip (T)") { library.showFilmstrip.toggle() }
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 18).padding(.horizontal, 4)
    }
}

struct OverlayButton: View {
    let systemImage: String
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint ?? .white)
                .frame(width: 34, height: 30)
                .background(Circle().fill(.white.opacity(hovering && isEnabled ? 0.15 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}
