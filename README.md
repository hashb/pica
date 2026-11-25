# Pica

A fast, Picasa/Pixea-style photo and video viewer for macOS (14+), written in Swift and SwiftUI with AppKit and AVFoundation underneath. There's no editing. Pica is for browsing, viewing and triaging: **favorite** or **delete** each item, and it moves the file into a folder you choose.

## Build & run

```bash
scripts/build-app.sh          # builds build/Pica.app (release)
open build/Pica.app
```

You can also run `swift run Pica ~/Pictures` during development, and `swift test` runs the tests.

To make video formats that macOS can't play work, install ffmpeg (`brew install ffmpeg`). Pica finds it in Homebrew, MacPorts, Nix or your login shell's `PATH`, or you can set its path in Settings.

## Features

- **Library sidebar**: add folders (or drop them on the window) and browse their subfolders. The sidebar also has **Favorites** and **Deleted** collections.
- **Thumbnail grid**: thumbnails load asynchronously and are cached, with duration badges on videos. Filter by All / Photos / Videos, filter by name, sort by name, date, size or type, optionally include subfolders, and resize thumbnails. The folder refreshes on its own when files change on disk.
- **Viewer**: like Picasa's photo viewer, it opens over the whole screen, with everything behind the photo dimmed and showing through. The menu bar and Dock hide; `Esc` closes it. In Settings you can choose Translucent, Blurred or Black and set how dark it is, or open the viewer inside the window instead. Also: fit / actual size / zoom (pinch, ⌘-scroll, double-click, `+` `-` `0` `1`), drag to pan, animated GIF/WebP/APNG, a filmstrip, and an info panel with EXIF (camera, lens, exposure, GPS) and video details. Neighbouring images are prefetched, so going next/previous is instant.
- **Favorite** (`F`): moves the file to your Favorites folder. Pressing `F` on an item that's already a favorite moves it back where it came from.
- **Delete** (`⌫`): moves the file to your Deleted folder. Deleting an item that's already in Deleted sends it to the macOS Trash, after asking first.
- **Empty Deleted on quit**: when you quit, Pica asks whether to empty the Deleted folder. Items on this Mac go to the macOS Trash. Items on network storage, which has no Trash, are deleted permanently, and the prompt warns about that. You can tick "Do the same every time", or pick Ask / Always empty / Never in Settings. Pica never asks when macOS is logging out or shutting down.
- **Restore** (`R`) and **Undo** (`⌘Z`): Pica stores each moved file's original path in an extended attribute (`com.pica.origin`), so you can restore it later, even after relaunching.
  Default folders are `~/Pictures/Pica/Favorites` and `~/Pictures/Pica/Deleted`. You can change them in Settings (`⌘,`).

### Formats

- **Images**: everything ImageIO decodes on your Mac, including JPEG, PNG, HEIC/HEIF, AVIF, WebP, JPEG XL, GIF, TIFF, BMP, PSD, ICO/ICNS, TGA, EXR, HDR, JPEG 2000, PBM/PGM/PPM and camera RAW (CR2/CR3, NEF, ARW, DNG, RAF, ORF, RW2…). SVG works through AppKit. Formats ImageIO can't read, such as QOI and PCX, fall back to ffmpeg.
- **Videos**: MP4, MOV, M4V and 3GP play directly. MKV, WebM, AVI, WMV, FLV, MPEG-TS/MTS/M2TS, MPG, VOB, OGV, RMVB, DivX, MXF and others play through ffmpeg. If the streams are already H.264/HEVC, Pica remuxes the file, which takes seconds. Otherwise it transcodes with the VideoToolbox hardware encoder. Results are cached in `~/Library/Caches/Pica` while Pica is open, so going back to a video is instant. The cache is deleted when Pica quits.

### Privacy

Pica keeps no record of your files after it quits. When you quit, and again at launch in case it crashed or was force-quit, it:

- deletes its cache (`~/Library/Caches/Pica`: converted videos, thumbnails, decoded images)
- deletes its per-app system caches and any saved window state
- stops any ffmpeg conversion still running
- forgets the last folder shown in Open dialogs

Thumbnails never go through Quick Look, whose cache is shared system-wide. Pica writes no logs.

Pica does keep its settings, including the folders in the sidebar and the last folder you viewed. It also keeps the original location of each file it moves to Favorites or Deleted, stored on that file, so Restore works.

### Video scrubbing

| Action | Hold | Tap |
|---|---|---|
| ⏪ / ⏩ buttons | scrub backward / forward | jump −5 s / +5 s |
| `J` / `L` | scrub backward / forward | jump −5 s / +5 s |
| `←` / `→` | scrub backward / forward | previous / next item |

Scrubbing starts at 2× and speeds up while you hold: 4×, 8×, 16× … up to 256× on long videos. Short clips are capped so they don't fly past. A large on-screen display shows the direction, speed and position. The starting speed is set in Settings.

Other video keys: `Space`/`K` play/pause, `,` `.` previous/next frame, `M` mute, `↑`/`↓` previous/next item. The timeline slider can also be dragged. Playback speed and loop are in the control bar.

## Keyboard

| Key | Grid | Viewer |
|---|---|---|
| Arrows | move selection (⇧ extends) | previous/next (hold ←/→ on video to scrub) |
| `Return` / `Space` | open viewer | back to grid / play-pause or next |
| `Esc` | clear selection | close the viewer |
| `F` | favorite / unfavorite | favorite / unfavorite |
| `⌫` | move to Deleted | move to Deleted |
| `R` | restore to original location | restore |
| `I`, `T` | — | info panel, filmstrip |
| `⌘Z` | undo last move | undo last move |

## Layout

```
Sources/Pica/
  App/        app entry, menus, keyboard routing (key-down/up for hold-to-scrub)
  Model/      Library (state, selection, move/undo), folder scanning & watching, formats
  Services/   ffmpeg integration, thumbnails, full-image loading, metadata
  Video/      VideoPlayerController (AVPlayer, coalesced seeking, scrubbing)
  Views/      SwiftUI views + the AppKit zoomable image view
Tests/PicaTests/   format detection, file moves, scrub behaviour, ffmpeg conversion
```
