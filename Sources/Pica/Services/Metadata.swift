import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct InfoRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

enum MetadataLoader {
    static func load(_ item: MediaItem) async -> [InfoRow] {
        var rows: [InfoRow] = [
            InfoRow(key: "Name", value: item.name),
            InfoRow(key: "Folder", value: item.url.deletingLastPathComponent().abbreviatedPath),
            InfoRow(key: "File size", value: Format.bytes(item.fileSize)),
            InfoRow(key: "Modified", value: Format.date.string(from: item.modified)),
            InfoRow(key: "Created", value: Format.date.string(from: item.created)),
        ]
        if let type = UTType(filenameExtension: item.ext)?.localizedDescription {
            rows.insert(InfoRow(key: "Kind", value: type), at: 1)
        }
        switch item.kind {
        case .image: rows += imageRows(item.url)
        case .video: rows += await videoRows(item.url)
        }
        if let origin = XAttr.get(Library.originAttribute, at: item.url) {
            rows.append(InfoRow(key: "Original location", value: (origin as NSString).abbreviatingWithTildeInPath))
        }
        return rows
    }

    private static func imageRows(_ url: URL) -> [InfoRow] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [] }
        var rows: [InfoRow] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { rows.append(InfoRow(key: k, value: v)) } }

        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            let mp = Double(w * h) / 1_000_000
            add("Dimensions", "\(w) × \(h)" + (mp >= 0.1 ? String(format: " (%.1f MP)", mp) : ""))
        }
        let count = CGImageSourceGetCount(src)
        if count > 1 { add("Frames", "\(count)") }
        if let depth = p[kCGImagePropertyDepth] as? Int { add("Bit depth", "\(depth)") }
        add("Color profile", p[kCGImagePropertyProfileName] as? String)

        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            add("Camera", (make.map { model.lowercased().hasPrefix($0.lowercased()) } ?? true) ? model : "\(make!) \(model)")
        } else {
            add("Camera", make)
        }
        add("Lens", exif[kCGImagePropertyExifLensModel] as? String)
        add("Date taken", exif[kCGImagePropertyExifDateTimeOriginal] as? String)
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            add("Exposure", t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t))
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { add("Aperture", String(format: "ƒ/%.1f", f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { add("ISO", "\(iso)") }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
            var s = String(format: "%.0f mm", fl)
            if let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int { s += " (\(f35) mm equiv.)" }
            add("Focal length", s)
        }
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            add("Location", String(format: "%.5f° %@, %.5f° %@", lat, latRef, lon, lonRef))
        }
        return rows
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        let s = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
        let names = ["avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "mp4v": "MPEG-4",
                     "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy",
                     "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "jpeg": "Motion JPEG", "av01": "AV1",
                     "vp09": "VP9", "aac": "AAC", "mp4a": "AAC", ".mp3": "MP3", "ac-3": "AC-3", "ec-3": "E-AC-3",
                     "alac": "Apple Lossless", "lpcm": "PCM", "opus": "Opus", "fLaC": "FLAC"]
        return names[s] ?? s
    }

    private static func videoRows(_ url: URL) async -> [InfoRow] {
        var rows: [InfoRow] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { rows.append(InfoRow(key: k, value: v)) } }

        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) == true,
           let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let d = try? await asset.load(.duration).seconds, d.isFinite { add("Duration", Format.duration(d)) }
            if let st = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: st.0).applying(st.1)
                add("Dimensions", "\(Int(abs(r.width))) × \(Int(abs(r.height)))")
            }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { add("Frame rate", String(format: "%.2f fps", fps)) }
            if let fmts = try? await track.load(.formatDescriptions), let f = fmts.first {
                add("Video codec", fourCC(CMFormatDescriptionGetMediaSubType(f)))
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                add("Bit rate", String(format: "%.1f Mbit/s", rate / 1_000_000))
            }
            if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
               let fmts = try? await audio.load(.formatDescriptions), let f = fmts.first {
                var s = fourCC(CMFormatDescriptionGetMediaSubType(f))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    s += " · \(Int(asbd.mChannelsPerFrame)) ch · \(Int(asbd.mSampleRate / 1000)) kHz"
                }
                add("Audio", s)
            }
            return rows
        }

        guard let info = await FFmpeg.probe(url) else {
            add("Playback", "Not supported by macOS — install ffmpeg to play this file")
            return rows
        }
        if let d = info.duration { add("Duration", Format.duration(d)) }
        if let w = info.width, let h = info.height { add("Dimensions", "\(w) × \(h)") }
        if let fps = info.frameRate { add("Frame rate", String(format: "%.2f fps", fps)) }
        add("Video codec", info.videoCodec?.uppercased())
        if let a = info.audioCodec { add("Audio", a.uppercased() + (info.audioChannels.map { " · \($0) ch" } ?? "")) }
        add("Playback", "Converted with ffmpeg")
        return rows
    }
}
