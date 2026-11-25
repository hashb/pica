import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @AppStorage(Prefs.Key.autoplay) private var autoplay = true
    @AppStorage(Prefs.Key.scrubSpeed) private var scrubSpeed = 2.0
    @AppStorage(Prefs.Key.upscale) private var upscale = false
    @AppStorage(Prefs.Key.showNames) private var showNames = true
    @AppStorage(Prefs.Key.ffmpegPath) private var ffmpegPath = ""
    @State private var ffmpegStatus = "Checking…"
    @State private var ffmpegFound = false
    @State private var cacheSize: Int64 = 0

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            video.tabItem { Label("Video", systemImage: "film") }
        }
        .frame(width: 580, height: 430)
        .task { await refresh() }
    }

    private var general: some View {
        @Bindable var library = library
        return Form {
            Section {
                folderRow("Deleted items go to", url: library.deletedFolder) { library.deletedFolder = $0 }
                folderRow("Favorites go to", url: library.favoritesFolder) { library.favoritesFolder = $0 }
            } header: {
                Text("Folders")
            } footer: {
                Text("Deleting or favoriting moves the file into these folders. Pica remembers where each file came from, so you can restore it (R) or undo (⌘Z). Deleting something that's already in the Deleted folder moves it to the macOS Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Browsing") {
                Toggle("Show file names under thumbnails", isOn: $showNames)
                Toggle("Enlarge small images to fill the window", isOn: $upscale)
            }
        }
        .formStyle(.grouped)
    }

    private var video: some View {
        @Bindable var controller = library.video
        return Form {
            Section("Playback") {
                Toggle("Start playing videos automatically", isOn: $autoplay)
                Toggle("Loop videos", isOn: $controller.loop)
                VStack(alignment: .leading) {
                    Slider(value: $scrubSpeed, in: 1...8, step: 1) {
                        Text("Hold-to-scrub starting speed")
                    }
                    Text("Starts at \(Int(scrubSpeed))× and doubles every second or so while held (up to \(Int(scrubSpeed * 128))×).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("ffmpeg path", text: $ffmpegPath, prompt: Text("Auto-detect"))
                    .onSubmit { Task { await refresh() } }
                HStack {
                    Image(systemName: ffmpegFound ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ffmpegFound ? .green : .orange)
                    Text(ffmpegStatus).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Check Again") { Task { await refresh() } }
                }
                HStack {
                    Text("Conversion & thumbnail cache: \(Format.bytes(cacheSize))")
                    Spacer()
                    Button("Clear Cache") {
                        FFmpeg.clearCache()
                        Task { await refresh() }
                    }
                }
            } header: {
                Text("ffmpeg")
            } footer: {
                Text("macOS plays MP4, MOV, M4V and 3GP itself. For MKV, WebM, AVI, WMV, FLV, MPEG-TS, OGV and others, Pica uses ffmpeg to remux or convert the file once and caches the result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: String, url: URL, set: @escaping (URL) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.abbreviatedPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = url
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let chosen = panel.url { set(chosen.folderURL) }
                }
                Button {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
            }
        }
    }

    private func refresh() async {
        FFmpeg.resetCache()
        let (ffmpeg, size) = await Task.detached { (FFmpeg.path(for: "ffmpeg"), FFmpeg.cacheSize()) }.value
        ffmpegFound = ffmpeg != nil
        ffmpegStatus = ffmpeg.map { "Using \($0)" } ?? "Not found. Install it (e.g. brew install ffmpeg) or enter its path above."
        cacheSize = size
    }
}
