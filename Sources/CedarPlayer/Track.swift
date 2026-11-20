import Foundation
import AVFoundation
import CoreMedia

struct Track: Identifiable, Hashable, Codable {
    let id: UUID
    var url: URL
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var sampleRate: Double
    var bitDepth: Int
    var channels: Int
    var bitrate: Int
    var albumArtist: String
    var trackNumber: Int
    var addedAt: Date
    var artwork: Data?
    var cueStart: TimeInterval?
    var cueEnd: TimeInterval?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.artist = ""
        self.album = ""
        self.duration = 0
        self.sampleRate = 0
        self.bitDepth = 0
        self.channels = 0
        self.bitrate = 0
        self.albumArtist = ""
        self.trackNumber = 0
        self.addedAt = Date()
        self.artwork = nil
        self.cueStart = nil
        self.cueEnd = nil
    }

    var displayTitle: String { title.isEmpty ? url.lastPathComponent : title }
    var displayArtist: String { artist.isEmpty ? "Неизвестный исполнитель" : artist }
    var displayAlbum: String { album.isEmpty ? "—" : album }

    var timeText: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var isCueTrack: Bool { cueStart != nil }

    var formatText: String {
        let ext = url.pathExtension.uppercased()
        if isCueTrack { return "\(ext) · CUE" }
        if ext == "FLAC" || ext == "ALAC" {
            return bitDepth > 0 ? "\(ext) \(bitDepth)/\(sampleRateKHz)" : ext
        }
        if sampleRate > 0 {
            return "\(ext) \(sampleRateKHz)"
        }
        return ext.isEmpty ? "AUDIO" : ext
    }

    /// Строка качества для прогресс-бара и списков.
    var qualityText: String {
        var parts: [String] = [url.pathExtension.uppercased()]
        if bitDepth > 0, sampleRate > 0 {
            parts.append("\(bitDepth) бит / \(sampleRateKHz)")
        } else if sampleRate > 0 {
            parts.append(sampleRateKHz)
        }
        if bitrate > 0 {
            parts.append("\(bitrate / 1000) кбит/с")
        }
        if isCueTrack, trackNumber > 0 {
            parts.append("CUE \(String(format: "%02d", trackNumber))")
        }
        return parts.joined(separator: " · ")
    }

    private var sampleRateKHz: String {
        let khz = sampleRate / 1000
        return khz == khz.rounded() ? String(format: "%.0f кГц", khz) : String(format: "%.1f кГц", khz)
    }

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "aif", "aiff", "aifc", "wav", "wave",
        "flac", "caf", "mp4", "m4b", "au", "sd2", "cue", "wv", "ape", "dsf", "dff"
    ]

    static func isSupported(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case added, title, artist, album, duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .added: return "По дате добавления"
        case .title: return "По названию"
        case .artist: return "По исполнителю"
        case .album: return "По альбому"
        case .duration: return "По длительности"
        }
    }
}

enum RepeatMode: String, Codable {
    case off, all, one

    var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var title: String {
        switch self {
        case .off: return "Повтор выключен"
        case .all: return "Повтор списка"
        case .one: return "Повтор трека"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
}

enum MetadataReader {
    static func read(url: URL) async -> Track {
        var track = Track(url: url)

        // 1. Собственные парсеры: FLAC (Vorbis + PICTURE) и ID3v2.
        let tags = TagReader.read(url: url)
        if let value = tags.title, !value.isEmpty { track.title = value }
        if let value = tags.artist, !value.isEmpty { track.artist = value }
        if let value = tags.album, !value.isEmpty { track.album = value }
        if let value = tags.albumArtist, !value.isEmpty { track.albumArtist = value }
        if let number = tags.trackNumber { track.trackNumber = number }
        if let art = tags.artwork { track.artwork = art }
        if let rate = tags.sampleRate { track.sampleRate = rate }
        if let depth = tags.bitDepth { track.bitDepth = depth }
        if let channels = tags.channels { track.channels = channels }
        if let duration = tags.duration { track.duration = duration }

        // 2. AVFoundation — то, что не удалось прочитать самим (m4a/aac и прочее).
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    if track.title.isEmpty, let value = try? await item.load(.stringValue) { track.title = value }
                case AVMetadataKey.commonKeyArtist.rawValue:
                    if track.artist.isEmpty, let value = try? await item.load(.stringValue) { track.artist = value }
                case AVMetadataKey.commonKeyAlbumName.rawValue:
                    if track.album.isEmpty, let value = try? await item.load(.stringValue) { track.album = value }
                case AVMetadataKey.commonKeyArtwork.rawValue:
                    if track.artwork == nil, let data = try? await item.load(.dataValue) { track.artwork = data }
                default:
                    break
                }
            }
        }

        if track.duration <= 0, let duration = try? await asset.load(.duration), duration.isValid {
            track.duration = CMTimeGetSeconds(duration)
        }

        if let file = try? AVAudioFile(forReading: url) {
            let format = file.processingFormat
            if track.sampleRate == 0 { track.sampleRate = format.sampleRate }
            if track.channels == 0 { track.channels = Int(format.channelCount) }
            if track.bitDepth == 0 { track.bitDepth = Int(format.streamDescription.pointee.mBitsPerChannel) }
            let bytesPerFrame = Double(format.streamDescription.pointee.mBytesPerFrame)
            track.bitrate = Int(bytesPerFrame * 8 * format.sampleRate)
            if track.duration <= 0, format.sampleRate > 0 {
                track.duration = Double(file.length) / format.sampleRate
            }
        }

        if track.artwork == nil {
            track.artwork = TagReader.folderArtwork(for: url)
        }

        return track
    }
}
