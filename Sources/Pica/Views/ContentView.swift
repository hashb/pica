import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeViewer: NavigationSplitViewVisibility = .all
    @AppStorage(Prefs.Key.viewerBackground) private var viewerBackground = ViewerBackground.translucent.rawValue

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 380)
        } detail: {
            ZStack {
                if library.viewerOpen && !library.viewerInOverlay {
                    ViewerView()
                } else {
                    BrowserView()
                }
            }
        }
        .navigationTitle(library.title)
        .navigationSubtitle(library.subtitle)
        .background(WindowAccessor { window in
            KeyboardRouter.shared.mainWindow = window
            updateWindowTranslucency()
        })
        .overlay(alignment: library.viewerOpen ? .top : .bottom) {
            ToastView()
                .animation(.spring(duration: 0.3), value: library.toast)
        }
        .onChange(of: viewerBackground) { updateWindowTranslucency() }
        .onChange(of: library.viewerOpen) { _, open in
            updateWindowTranslucency()
            if open && library.viewerInOverlay {
                ViewerOverlay.shared.show(library: library, over: KeyboardRouter.shared.mainWindow)
                return
            }
            if !open { ViewerOverlay.shared.hide() }
            withAnimation(.easeInOut(duration: 0.2)) {
                if open {
                    visibilityBeforeViewer = columnVisibility
                    columnVisibility = .detailOnly
                } else if columnVisibility == .detailOnly {
                    columnVisibility = visibilityBeforeViewer
                }
            }
        }
        .modifier(ViewerToolbarStyle(viewerOpen: library.viewerOpen && !library.viewerInOverlay))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in Library.shared.open(urls: [url]) }
                }
            }
            return true
        }
    }

    /// While the viewer is open the window itself becomes see-through so the
    /// desktop shows behind the photo; the backdrop view then tints or blurs it.
    private func updateWindowTranslucency() {
        guard let window = KeyboardRouter.shared.mainWindow else { return }
        let seeThrough = library.viewerOpen && !library.viewerInOverlay && (ViewerBackground(rawValue: viewerBackground) ?? .translucent).seeThrough
        window.isOpaque = !seeThrough
        window.backgroundColor = seeThrough ? .clear : .windowBackgroundColor
    }
}

/// Lets the viewer's backdrop show through the toolbar area too (macOS 15+).
private struct ViewerToolbarStyle: ViewModifier {
    let viewerOpen: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbarBackgroundVisibility(viewerOpen ? .hidden : .automatic, for: .windowToolbar)
        } else {
            content
        }
    }
}
