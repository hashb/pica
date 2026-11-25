import SwiftUI

struct BrowserView: View {
    @Environment(Library.self) private var library
    @AppStorage(Prefs.Key.thumbSize) private var thumbSize = 170.0
    @AppStorage(Prefs.Key.showNames) private var showNames = true

    var body: some View {
        @Bindable var library = library
        Group {
            if library.selectedFolder == nil {
                EmptyStateView()
            } else if library.items.isEmpty {
                if library.isScanning {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        library.searchText.isEmpty ? "No Photos or Videos" : "No Matches",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(emptyMessage))
                }
            } else {
                MediaGridView(thumbSize: thumbSize, showNames: showNames)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Filter by name")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("Show", selection: $library.filter) {
                    ForEach(MediaFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .help("Show photos, videos or both")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $library.includeSubfolders) {
                    Label("Include Subfolders", systemImage: "square.stack.3d.down.right")
                }
                .help("Include media from subfolders")

                Menu {
                    Picker("Sort By", selection: $library.sortKey) {
                        ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("Order", selection: $library.sortAscending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort order")

                Slider(value: $thumbSize, in: 90...380) {
                    Label("Thumbnail Size", systemImage: "square.grid.2x2")
                }
                .frame(width: 110)
                .help("Thumbnail size")

                Button {
                    library.toggleFavoriteTargets()
                } label: {
                    Label("Favorite", systemImage: "star")
                }
                .help("Move to Favorites (F)")
                .disabled(library.actionTargets.isEmpty)

                Button {
                    library.deleteTargets()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Move to the Deleted folder (⌫)")
                .disabled(library.actionTargets.isEmpty)
            }
        }
    }
}

extension BrowserView {
    private var emptyMessage: String {
        if !library.searchText.isEmpty { return "Nothing matches “\(library.searchText)”." }
        if library.selectedFolder == library.favoritesFolder { return "Press F on a photo or video to move it here." }
        if library.selectedFolder == library.deletedFolder { return "Items you delete are moved here. Press R to restore one." }
        if library.filter != .all { return "No \(library.filter.title.lowercased()) in this folder." }
        return library.includeSubfolders ? "This folder and its subfolders have no media." : "Try including subfolders, or pick another folder."
    }
}

struct MediaGridView: View {
    let thumbSize: Double
    let showNames: Bool
    @Environment(Library.self) private var library
    private let spacing: CGFloat = 10
    private let padding: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - padding * 2 + spacing) / (thumbSize + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols), spacing: spacing) {
                        ForEach(library.items) { item in
                            GridCell(
                                item: item,
                                size: thumbSize,
                                isSelected: library.selection.contains(item.url),
                                isFocused: library.focused == item.url,
                                isFavorite: library.isFavorite(item.url),
                                showName: showNames
                            )
                            .id(item.url)
                            .onTapGesture { library.click(item.url) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { library.openViewer(at: item.url) })
                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                            .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                    .padding(padding)
                }
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { library.clearSelection() }
                )
                .onAppear {
                    library.gridColumns = cols
                    if let f = library.focused { proxy.scrollTo(f, anchor: .center) }
                }
                .onChange(of: cols) { _, c in library.gridColumns = c }
                .onChange(of: library.focused) { _, f in
                    if let f { proxy.scrollTo(f) }
                }
            }
        }
    }
}

struct GridCell: View {
    let item: MediaItem
    let size: Double
    let isSelected: Bool
    let isFocused: Bool
    let isFavorite: Bool
    let showName: Bool

    @State private var thumb: Thumbnail?
    @State private var failed = false

    init(item: MediaItem, size: Double, isSelected: Bool, isFocused: Bool, isFavorite: Bool, showName: Bool) {
        self.item = item
        self.size = size
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.isFavorite = isFavorite
        self.showName = showName
        _thumb = State(initialValue: ThumbnailService.shared.cached(item.url))
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                } else if failed {
                    VStack(spacing: 6) {
                        Image(systemName: item.kind == .video ? "film" : "photo")
                            .font(.system(size: 30))
                        Text(item.ext.uppercased()).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: size)
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        if let d = thumb?.duration { Text(Format.duration(d)).monospacedDigit() }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
            )

            if showName {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .help(item.name)
        .task(id: item.url) {
            guard thumb == nil else { return }
            let t = await ThumbnailService.shared.thumbnail(for: item)
            if Task.isCancelled { return }
            thumb = t
            failed = t == nil
        }
    }
}

struct ItemContextMenu: View {
    let item: MediaItem
    @Environment(Library.self) private var library

    var body: some View {
        Button("Open") { library.openViewer(at: item.url) }
        Divider()
        Button(library.isFavorite(item.url) ? "Remove from Favorites" : "Move to Favorites") {
            library.prepareContextTarget(item.url)
            library.toggleFavoriteTargets()
        }
        Button(library.isInDeleted(item.url) ? "Move to Trash…" : "Move to Deleted") {
            library.prepareContextTarget(item.url)
            library.deleteTargets()
        }
        if library.canRestore(item.url) {
            Button("Restore to Original Location") {
                library.prepareContextTarget(item.url)
                library.restoreTargets()
            }
        }
        Divider()
        Button("Reveal in Finder") {
            library.prepareContextTarget(item.url)
            library.revealTargets()
        }
        Button("Open in Default App") {
            library.prepareContextTarget(item.url)
            library.openTargetsInDefaultApp()
        }
        Button("Copy") {
            library.prepareContextTarget(item.url)
            library.copyTargetPaths()
        }
    }
}

struct StatusBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 8) {
            if library.selectedFolder != nil {
                Text(summary)
                if library.selection.count > 1 {
                    Text("· \(library.selection.count) selected")
                }
            }
            Spacer()
            if library.isScanning {
                ProgressView().controlSize(.mini)
            }
            Text("F favorite · ⌫ delete · ↩ open")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var summary: String {
        var parts = ["\(library.items.count) items"]
        if library.photoCount > 0 { parts.append("\(library.photoCount) photos") }
        if library.videoCount > 0 { parts.append("\(library.videoCount) videos") }
        return parts.joined(separator: " · ")
    }
}

struct EmptyStateView: View {
    @Environment(Library.self) private var library

    private var suggestions: [(String, URL)] {
        let fm = FileManager.default
        let dirs: [(String, FileManager.SearchPathDirectory)] = [
            ("Pictures", .picturesDirectory), ("Movies", .moviesDirectory),
            ("Desktop", .desktopDirectory), ("Downloads", .downloadsDirectory),
        ]
        return dirs.compactMap { name, dir in
            fm.urls(for: dir, in: .userDomainMask).first.map { (name, $0) }
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.secondary)
            Text("Add a folder to start browsing")
                .font(.title2.weight(.semibold))
            Text("Pica shows the photos and videos in your folders.\nDrop a folder on this window, or choose one.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Folder…") { library.addFolderWithPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            HStack {
                ForEach(suggestions, id: \.0) { name, url in
                    Button(name) { library.addRoot(url) }
                }
            }
            .controlSize(.small)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
