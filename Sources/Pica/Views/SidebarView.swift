import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        let _ = library.treeVersion  // re-read folder children after a refresh
        List(selection: $library.selectedFolder) {
            Section("Collections") {
                Label {
                    Text("Favorites")
                } icon: {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                .tag(library.favoritesFolder)
                .help(library.favoritesFolder.abbreviatedPath)
                .contextMenu { folderMenu(library.favoritesFolder, isRoot: false) }

                Label {
                    Text("Deleted")
                } icon: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .tag(library.deletedFolder)
                .help(library.deletedFolder.abbreviatedPath)
                .contextMenu { folderMenu(library.deletedFolder, isRoot: false) }
            }

            Section("Folders") {
                if library.roots.isEmpty {
                    Text("Add a folder to get started")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if library.rootNodes.isEmpty && library.hiddenRootCount > 0 {
                    Text("No folders with photos or videos")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                OutlineGroup(library.rootNodes, children: \.children) { node in
                    Label(node.name, systemImage: library.roots.contains(node.url) ? "folder.fill" : "folder")
                        .tag(node.url)
                        .help(node.url.abbreviatedPath)
                        .contextMenu { folderMenu(node.url, isRoot: library.roots.contains(node.url)) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    library.addFolderWithPanel()
                } label: {
                    Label("Add Folder", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func folderMenu(_ url: URL, isRoot: Bool) -> some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Refresh") { library.rebuildTree(); if library.selectedFolder == url { library.rescan() } }
        if isRoot {
            Divider()
            Button("Remove from Sidebar") { library.removeRoot(url) }
        }
    }
}
