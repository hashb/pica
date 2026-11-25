import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeViewer: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 380)
        } detail: {
            ZStack {
                if library.viewerOpen {
                    ViewerView()
                } else {
                    BrowserView()
                }
            }
        }
        .navigationTitle(library.title)
        .navigationSubtitle(library.subtitle)
        .background(WindowAccessor { KeyboardRouter.shared.mainWindow = $0 })
        .overlay(alignment: library.viewerOpen ? .top : .bottom) {
            ToastView()
                .animation(.spring(duration: 0.3), value: library.toast)
        }
        .onChange(of: library.viewerOpen) { _, open in
            withAnimation(.easeInOut(duration: 0.2)) {
                if open {
                    visibilityBeforeViewer = columnVisibility
                    columnVisibility = .detailOnly
                } else {
                    columnVisibility = visibilityBeforeViewer
                }
            }
        }
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
}
