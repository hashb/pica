import AppKit
import Observation

enum SortKey: String, CaseIterable, Identifiable {
    case name, dateModified, dateCreated, size, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .size: "Size"
        case .kind: "Type"
        }
    }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all, photos, videos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var canUndo = false
    var isError = false
}

struct MoveRecord {
    let from: URL
    let to: URL
    let previousOrigin: String?
}

/// App state: folders, the current listing, selection, viewer state and file actions.
@MainActor @Observable
final class Library {
    static let shared = Library()
    /// Extended attribute that stores the original path of a file we moved.
    nonisolated static let originAttribute = "com.pica.origin"

    // MARK: Folders & options

    var roots: [URL] {
        didSet {
            Prefs.d.set(roots.map(\.path), forKey: Prefs.Key.roots)
            rebuildTree()
        }
    }
    private(set) var rootNodes: [FolderNode] = []

    var deletedFolder: URL {
        didSet { Prefs.d.set(deletedFolder.path, forKey: Prefs.Key.deletedFolder); rebuildTree() }
    }
    var favoritesFolder: URL {
        didSet { Prefs.d.set(favoritesFolder.path, forKey: Prefs.Key.favoritesFolder); rebuildTree() }
    }

    var selectedFolder: URL? {
        didSet {
            guard oldValue != selectedFolder else { return }
            Prefs.d.set(selectedFolder?.path, forKey: Prefs.Key.selectedFolder)
            viewerOpen = false
            selection = []
            focused = nil
            anchor = nil
            lastFocusIndex = 0
            allItems = []
            apply()
            rescan()
            startWatching()
        }
    }

    var includeSubfolders: Bool {
        didSet { Prefs.d.set(includeSubfolders, forKey: Prefs.Key.includeSubfolders); rescan() }
    }
    var sortKey: SortKey {
        didSet { Prefs.d.set(sortKey.rawValue, forKey: Prefs.Key.sortKey); apply() }
    }
    var sortAscending: Bool {
        didSet { Prefs.d.set(sortAscending, forKey: Prefs.Key.sortAscending); apply() }
    }
    var filter: MediaFilter {
        didSet { Prefs.d.set(filter.rawValue, forKey: Prefs.Key.filter); apply() }
    }
    var searchText = "" { didSet { if oldValue != searchText { apply() } } }

    // MARK: Listing & selection

    private(set) var allItems: [MediaItem] = []
    private(set) var items: [MediaItem] = []
    private(set) var photoCount = 0
    private(set) var videoCount = 0
    @ObservationIgnored private var indexByURL: [URL: Int] = [:]

    var selection: Set<URL> = []
    var focused: URL? {
        didSet {
            guard oldValue != focused else { return }
            if let f = focused, let i = indexByURL[f] { lastFocusIndex = i }
            syncPlayback()
        }
    }
    @ObservationIgnored private var anchor: URL?
    @ObservationIgnored private var lastFocusIndex = 0

    var viewerOpen = false {
        didSet {
            guard oldValue != viewerOpen else { return }
            if viewerOpen { viewerInOverlay = Prefs.viewerFullScreen }
            syncPlayback()
        }
    }
    /// Whether the open viewer is the full-screen overlay (decided each time it opens).
    private(set) var viewerInOverlay = false
    var showInfo = false
    var showFilmstrip: Bool { didSet { Prefs.d.set(showFilmstrip, forKey: Prefs.Key.showFilmstrip) } }
    private(set) var isScanning = false
    var toast: Toast?
    var gridColumns = 1

    let video = VideoPlayerController()
    let zoom = ZoomController()

    private(set) var undoStack: [[MoveRecord]] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var pendingFocus: URL?
    @ObservationIgnored private var pendingOpenViewer = false

    init() {
        Prefs.registerDefaults()
        let d = Prefs.d
        roots = (d.stringArray(forKey: Prefs.Key.roots) ?? []).map { URL.folder($0) }
        deletedFolder = d.string(forKey: Prefs.Key.deletedFolder).flatMap { $0.isEmpty ? nil : URL.folder($0) }
            ?? Prefs.defaultDeletedFolder
        favoritesFolder = d.string(forKey: Prefs.Key.favoritesFolder).flatMap { $0.isEmpty ? nil : URL.folder($0) }
            ?? Prefs.defaultFavoritesFolder
        includeSubfolders = d.bool(forKey: Prefs.Key.includeSubfolders)
        sortKey = SortKey(rawValue: d.string(forKey: Prefs.Key.sortKey) ?? "") ?? .name
        sortAscending = d.bool(forKey: Prefs.Key.sortAscending)
        filter = MediaFilter(rawValue: d.string(forKey: Prefs.Key.filter) ?? "") ?? .all
        showFilmstrip = d.bool(forKey: Prefs.Key.showFilmstrip)
        rootNodes = roots.map(FolderNode.init)
        if let p = d.string(forKey: Prefs.Key.selectedFolder), FileManager.default.fileExists(atPath: p) {
            selectedFolder = URL.folder(p)
            DispatchQueue.main.async { [weak self] in
                self?.rescan()
                self?.startWatching()
            }
        }
    }

    // MARK: Derived

    var currentIndex: Int? { focused.flatMap { indexByURL[$0] } }
    var currentItem: MediaItem? { currentIndex.map { items[$0] } }
    func index(of url: URL) -> Int? { indexByURL[url] }

    var title: String {
        if viewerOpen, let item = currentItem { return item.name }
        guard let folder = selectedFolder else { return "Pica" }
        if folder == favoritesFolder { return "Favorites" }
        if folder == deletedFolder { return "Deleted" }
        return FileManager.default.displayName(atPath: folder.path)
    }

    var subtitle: String {
        if viewerOpen, let i = currentIndex { return "\(i + 1) of \(items.count)" }
        return selectedFolder?.abbreviatedPath ?? ""
    }

    func isFavorite(_ url: URL) -> Bool { url.isDescendant(of: favoritesFolder) }
    func isInDeleted(_ url: URL) -> Bool { url.isDescendant(of: deletedFolder) }
    func origin(of url: URL) -> URL? {
        XAttr.get(Self.originAttribute, at: url).map { URL(fileURLWithPath: $0) }
    }
    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: Folder management

    func addRoot(_ url: URL, select: Bool = true) {
        let folder = url.folderURL
        if !roots.contains(folder) { roots.append(folder) }
        if select { selectedFolder = folder }
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url.folderURL }
        if let s = selectedFolder, s.isSameOrDescendant(of: url),
           !roots.contains(where: { s.isSameOrDescendant(of: $0) }) {
            selectedFolder = nil
        }
    }

    func rebuildTree() { rootNodes = roots.map(FolderNode.init) }

    func addFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders with photos and videos"
        guard panel.runModal() == .OK else { return }
        for (i, url) in panel.urls.enumerated() { addRoot(url, select: i == 0) }
    }

    func openFilesWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    /// Opens a folder (adds it to the sidebar) or a file (shows its folder and opens it in the viewer).
    func open(urls: [URL]) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            addRoot(first)
            return
        }
        let file = first.fileURL
        let parent = file.deletingLastPathComponent().folderURL
        if !roots.contains(where: { parent.isSameOrDescendant(of: $0) }) { roots.append(parent) }
        filter = .all
        searchText = ""
        pendingFocus = file
        pendingOpenViewer = true
        if selectedFolder != parent {
            selectedFolder = parent
        } else {
            rescan()
        }
    }

    // MARK: Scanning

    func rescan() {
        scanTask?.cancel()
        guard let folder = selectedFolder else {
            isScanning = false
            allItems = []
            apply()
            return
        }
        isScanning = true
        let recursive = includeSubfolders
        let excluded = [deletedFolder, favoritesFolder].filter { $0.isDescendant(of: folder) }
        scanTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(folder, recursive: recursive, excluding: excluded)
            }.value
            guard let self, !Task.isCancelled, self.selectedFolder == folder else { return }
            self.allItems = found
            self.isScanning = false
            self.apply()
            self.handlePending()
        }
    }

    private func startWatching() {
        watcher = nil
        guard let folder = selectedFolder else { return }
        watcher = FolderWatcher(url: folder) { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    private func handlePending() {
        if let p = pendingFocus, indexByURL[p] != nil {
            focus(p)
            if pendingOpenViewer { viewerOpen = true }
        }
        pendingFocus = nil
        pendingOpenViewer = false
    }

    /// Filters and sorts `allItems` into `items`, keeping selection and focus valid.
    func apply() {
        var list = allItems
        switch filter {
        case .all: break
        case .photos: list.removeAll { $0.kind != .image }
        case .videos: list.removeAll { $0.kind != .video }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) } }

        let key = sortKey, asc = sortAscending
        list.sort { a, b in
            var r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .dateModified: r = a.modified.compare(b.modified)
            case .dateCreated: r = a.created.compare(b.created)
            case .size: r = a.fileSize == b.fileSize ? .orderedSame : (a.fileSize < b.fileSize ? .orderedAscending : .orderedDescending)
            case .kind: r = a.ext.compare(b.ext)
            }
            if r == .orderedSame { r = a.url.path.localizedStandardCompare(b.url.path) }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }

        items = list
        var idx = [URL: Int](minimumCapacity: list.count)
        var photos = 0
        for (i, item) in list.enumerated() {
            idx[item.url] = i
            if item.kind == .image { photos += 1 }
        }
        indexByURL = idx
        photoCount = photos
        videoCount = list.count - photos

        let validSelection = selection.filter { idx[$0] != nil }
        if validSelection != selection { selection = validSelection }
        if let f = focused, idx[f] != nil {
            // keep focus
        } else if !list.isEmpty {
            focused = list[min(lastFocusIndex, list.count - 1)].url
        } else {
            focused = nil
        }
        if items.isEmpty && viewerOpen { viewerOpen = false }
    }

    // MARK: Navigation & selection

    func focus(_ url: URL) {
        focused = url
        selection = [url]
        anchor = url
    }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let i = currentIndex ?? 0
        focus(items[min(max(i + delta, 0), items.count - 1)].url)
    }

    func goToFirst() { if let f = items.first { focus(f.url) } }
    func goToLast() { if let l = items.last { focus(l.url) } }

    func moveFocus(by delta: Int, extend: Bool) {
        guard !items.isEmpty else { return }
        guard let i = currentIndex else { focus(items[0].url); return }
        let n = min(max(i + delta, 0), items.count - 1)
        if extend, let a = anchor, let ai = indexByURL[a] {
            focused = items[n].url
            selection = Set(items[min(ai, n)...max(ai, n)].map(\.url))
        } else {
            focus(items[n].url)
        }
    }

    func click(_ url: URL) {
        resignSidebarFocus()
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
            focused = url
            anchor = url
        } else if mods.contains(.shift), let a = anchor, let ai = indexByURL[a], let bi = indexByURL[url] {
            selection = Set(items[min(ai, bi)...max(ai, bi)].map(\.url))
            focused = url
        } else {
            focus(url)
        }
    }

    /// Before a context-menu action: act on the selection if the item is part of it, otherwise on the item.
    func prepareContextTarget(_ url: URL) {
        if !selection.contains(url) { focus(url) }
    }

    func selectAll() { selection = Set(items.map(\.url)) }
    func clearSelection() { selection = [] }

    func openViewer(at url: URL? = nil) {
        if let url { focus(url) }
        guard currentItem != nil else { return }
        resignSidebarFocus()
        viewerOpen = true
    }

    func closeViewer() {
        viewerOpen = false
        if let f = focused { selection = [f] }
    }

    func toggleViewer() { viewerOpen ? closeViewer() : openViewer() }

    private func resignSidebarFocus() {
        KeyboardRouter.shared.mainWindow?.makeFirstResponder(nil)
    }

    private func syncPlayback() {
        guard viewerOpen, let item = currentItem else {
            video.stop()
            return
        }
        if item.kind == .video {
            video.load(item.url, autoplay: Prefs.autoplay)
        } else {
            video.stop()
        }
        prefetchNeighbors()
    }

    private func prefetchNeighbors() {
        guard let i = currentIndex else { return }
        let urls = [i + 1, i - 1, i + 2]
            .filter { items.indices.contains($0) }
            .map { items[$0] }
            .filter { $0.kind == .image }
            .map(\.url)
        ImageLoader.shared.prefetch(urls)
    }

    // MARK: Actions

    /// In the viewer: the current item. In the grid: the selection (or the focused item).
    var actionTargets: [URL] {
        if viewerOpen { return currentItem.map { [$0.url] } ?? [] }
        if !selection.isEmpty { return items.filter { selection.contains($0.url) }.map(\.url) }
        return currentItem.map { [$0.url] } ?? []
    }

    func deleteTargets() {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        let alreadyDeleted = targets.filter(isInDeleted)
        let others = targets.filter { !isInDeleted($0) }
        if !others.isEmpty {
            perform(others.map { .init(source: $0, directory: deletedFolder, name: $0.lastPathComponent, setOrigin: true) }) {
                "Moved \(Self.count($0)) to Deleted"
            }
        }
        if !alreadyDeleted.isEmpty { moveToSystemTrash(alreadyDeleted) }
    }

    func toggleFavoriteTargets() {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        let toFavorite = targets.filter { !isFavorite($0) }
        if !toFavorite.isEmpty {
            perform(toFavorite.map { .init(source: $0, directory: favoritesFolder, name: $0.lastPathComponent, setOrigin: true) }) {
                "Moved \(Self.count($0)) to Favorites"
            }
        } else {
            restore(targets, message: { "Removed \(Self.count($0)) from Favorites" })
        }
    }

    func restoreTargets() {
        restore(actionTargets, message: { "Restored \(Self.count($0))" })
    }

    func canRestore(_ url: URL) -> Bool { origin(of: url) != nil }

    private func restore(_ urls: [URL], message: @escaping (Int) -> String) {
        var requests: [MoveRequest] = []
        var unknown = 0
        for url in urls {
            guard let o = origin(of: url) else { unknown += 1; continue }
            requests.append(.init(source: url, directory: o.deletingLastPathComponent().folderURL, name: o.lastPathComponent, setOrigin: false))
        }
        if !requests.isEmpty { perform(requests, message: message) }
        if unknown > 0 && requests.isEmpty {
            toast = Toast(message: "The original location of \(Self.count(unknown)) isn't known", isError: true)
        }
    }

    private struct MoveRequest {
        let source: URL
        let directory: URL
        let name: String
        let setOrigin: Bool
    }

    private func perform(_ requests: [MoveRequest], message: (Int) -> String) {
        let fm = FileManager.default
        let firstIndex = requests.compactMap { indexByURL[$0.source] }.min()
        var records: [MoveRecord] = []
        var errors: [String] = []
        for r in requests {
            do {
                try fm.createDirectory(at: r.directory, withIntermediateDirectories: true)
                let dest = FileOps.uniqueDestination(name: r.name, in: r.directory)
                let previous = XAttr.get(Self.originAttribute, at: r.source)
                try fm.moveItem(at: r.source, to: dest)
                if r.setOrigin {
                    XAttr.set(Self.originAttribute, r.source.path, at: dest)
                } else {
                    XAttr.remove(Self.originAttribute, at: dest)
                }
                records.append(MoveRecord(from: r.source, to: dest, previousOrigin: previous))
            } catch {
                errors.append("\(r.source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !records.isEmpty {
            undoStack.append(records)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        removeFromView(Set(records.map(\.from)), preferIndex: firstIndex)
        if let e = errors.first {
            toast = Toast(message: errors.count == 1 ? "Couldn't move \(e)" : "Couldn't move \(errors.count) items. \(e)", isError: true)
        } else if !records.isEmpty {
            toast = Toast(message: message(records.count), canUndo: true)
        }
    }

    private func moveToSystemTrash(_ urls: [URL]) {
        let alert = NSAlert()
        alert.messageText = "Move \(Self.count(urls.count)) to the Trash?"
        alert.informativeText = "These items are already in your Deleted folder. They will be moved to the macOS Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let firstIndex = urls.compactMap { indexByURL[$0] }.min()
        var trashed: Set<URL> = []
        for url in urls {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { trashed.insert(url) }
        }
        removeFromView(trashed, preferIndex: firstIndex)
        toast = Toast(message: "Moved \(Self.count(trashed.count)) to the Trash")
    }

    private func removeFromView(_ urls: Set<URL>, preferIndex: Int?) {
        guard !urls.isEmpty else { return }
        allItems.removeAll { urls.contains($0.url) }
        if let i = preferIndex { lastFocusIndex = i }
        selection.subtract(urls)
        if let f = focused, urls.contains(f) { focused = nil }
        apply()
        if viewerOpen, let f = focused { selection = [f] }
    }

    var undoTitle: String {
        guard let last = undoStack.last else { return "Undo" }
        return "Undo Move of \(Self.count(last.count))"
    }

    func undo() {
        guard let records = undoStack.popLast() else { return }
        let fm = FileManager.default
        var restored: [URL] = []
        for r in records.reversed() {
            do {
                let dir = r.from.deletingLastPathComponent()
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = fm.fileExists(atPath: r.from.path)
                    ? FileOps.uniqueDestination(name: r.from.lastPathComponent, in: dir) : r.from
                try fm.moveItem(at: r.to, to: dest)
                if let p = r.previousOrigin {
                    XAttr.set(Self.originAttribute, p, at: dest)
                } else {
                    XAttr.remove(Self.originAttribute, at: dest)
                }
                restored.append(dest.fileURL)
            } catch {
                toast = Toast(message: "Couldn't undo: \(error.localizedDescription)", isError: true)
            }
        }
        pendingFocus = restored.last
        pendingOpenViewer = viewerOpen
        rescan()
        if !restored.isEmpty { toast = Toast(message: "Put back \(Self.count(restored.count))") }
    }

    // MARK: Misc

    func revealTargets() {
        let urls = actionTargets
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func openTargetsInDefaultApp() {
        for url in actionTargets { NSWorkspace.shared.open(url) }
    }

    func copyTargetPaths() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(actionTargets as [NSURL])
    }

    nonisolated static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
}
