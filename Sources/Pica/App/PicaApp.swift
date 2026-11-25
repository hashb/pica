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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Leftovers from a crash or force-quit. Runs before any file is opened.
        Privacy.purge()
    }

    private var services: ServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let provider = ServiceProvider()
        services = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
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
        }
    }

    /// Offers to empty the Deleted folder before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let mode = Prefs.emptyDeletedOnQuit
        guard mode != .never, !DeletedFolderCleaner.isSystemQuit else { return .terminateNow }
        let items = DeletedFolderCleaner.items(in: Library.shared.deletedFolder)
        guard !items.isEmpty else { return .terminateNow }

        if mode == .ask {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Empty the Deleted folder before quitting?"
            alert.informativeText = DeletedFolderCleaner.message(for: items)
            alert.alertStyle = items.contains(where: \.isNetwork) ? .critical : .warning
            let empty = alert.addButton(withTitle: "Empty and Quit")
            empty.hasDestructiveAction = items.contains(where: \.isNetwork)
            alert.addButton(withTitle: "Quit Without Emptying")
            // Only offer Cancel if there's a window to go back to (closing the last window also quits).
            if NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
                alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            }
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do the same every time I quit"

            let response = alert.runModal()
            let remember = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn:
                if remember { Prefs.emptyDeletedOnQuit = .always }
            case .alertSecondButtonReturn:
                if remember { Prefs.emptyDeletedOnQuit = .never }
                return .terminateNow
            default:
                return .terminateCancel
            }
        }

        Library.shared.video.stop()
        Task.detached(priority: .userInitiated) {
            let result = DeletedFolderCleaner.empty(items)
            await MainActor.run {
                if !result.failures.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Some items couldn't be removed from the Deleted folder"
                    alert.informativeText = result.failures.prefix(5).joined(separator: "\n")
                        + (result.failures.count > 5 ? "\n…and \(result.failures.count - 5) more" : "")
                    alert.addButton(withTitle: "Quit")
                    alert.runModal()
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Library.shared.video.stop()
        Privacy.purge()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Library.shared.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Handles the "Explore with Pica" service in Finder's right-click menu (declared in Info.plist).
@MainActor
final class ServiceProvider: NSObject {
    @objc func exploreWithPica(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let first = urls.first else {
            error.pointee = "Pica didn't receive a file or folder." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Library.shared.explore(first)
    }
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
