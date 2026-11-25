import AppKit
import SwiftUI

@main
struct PicaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = Library.shared

    var body: some Scene {
        Window("Pica", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1240, height: 820)
        .commands { PicaCommands(library: library) }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        KeyboardRouter.shared.install()

        // Paths passed on the command line (`Pica.app/Contents/MacOS/Pica ~/Pictures`).
        let paths = CommandLine.arguments.dropFirst()
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty {
            Library.shared.open(urls: paths.map { URL(fileURLWithPath: $0) })
        }

        Task.detached(priority: .background) {
            _ = FFmpeg.path(for: "ffmpeg")
            _ = FFmpeg.path(for: "ffprobe")
            FFmpeg.pruneConverted()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Library.shared.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PicaCommands: Commands {
    let library: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") { library.addFolderWithPanel() }
                .keyboardShortcut("o")
            Button("Open File…") { library.openFilesWithPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(library.undoTitle) { library.undo() }
                .keyboardShortcut("z")
                .disabled(!library.canUndo)
        }
        CommandMenu("Media") {
            Button("Toggle Favorite  (F)") { library.toggleFavoriteTargets() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Move to Deleted Folder  (⌫)") { library.deleteTargets() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Restore to Original Location  (R)") { library.restoreTargets() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Reveal in Finder") { library.revealTargets() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Open in Default App") { library.openTargetsInDefaultApp() }
            Divider()
            Button("Refresh Folder") { library.rescan(); library.rebuildTree() }
                .keyboardShortcut("r")
        }
        CommandGroup(after: .sidebar) {
            Button(library.viewerOpen ? "Back to Thumbnails" : "Open Viewer") { library.toggleViewer() }
                .keyboardShortcut(.return, modifiers: .command)
            Button(library.showInfo ? "Hide Info" : "Show Info") { library.showInfo.toggle() }
                .keyboardShortcut("i")
            Button(library.showFilmstrip ? "Hide Filmstrip" : "Show Filmstrip") { library.showFilmstrip.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
        }
    }
}
