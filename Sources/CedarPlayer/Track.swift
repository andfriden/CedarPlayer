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
    var genre: String
    var year: String
    var composer: String
    var trackNumber: Int
    var discNumber: Int
    var rating: Int
    var addedAt: Date
    var artwork: Data?
    var artworkID: String?
    var replayGainDB: Double?
    var replayGainPeak: Double?
    var cueStart: TimeInterval?
    var cueEnd: TimeInterval?
    /// File was missing on the last check; not written to JSON.
    var isMissing: Bool = false

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
        self.genre = ""
        self.year = ""
        self.composer = ""
        self.trackNumber = 0
        self.discNumber = 0
        self.rating = 0
        self.addedAt = Date()
        self.artwork = nil
        self.artworkID = nil
        self.replayGainDB = nil
        self.replayGainPeak = nil
        self.cueStart = nil
        self.cueEnd = nil
    }

    var displayTitle: String { title.isEmpty ? url.lastPathComponent : title }
    var displayArtist: String { artist.isEmpty ? L10n.string("Неизвестный исполнитель") : artist }
    var displayAlbum: String { album.isEmpty ? "—" : album }

    var timeText: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var isCueTrack: Bool { cueStart != nil }

    var replayGainText: String? {
        guard let gain = replayGainDB else { return nil }
        return "ReplayGain \(ReplayGain.text(gain))"
    }

    /// Tooltip: format, genre, year, composer, ReplayGain.
    var extendedInfoText: String {
        var parts: [String] = [qualityText]
        if !genre.isEmpty { parts.append(genre) }
        if !year.isEmpty { parts.append(year) }
        if !composer.isEmpty { parts.append(composer) }
        if let replayGainText { parts.append(replayGainText) }
        if isMissing { parts.append(L10n.string("файл не найден")) }
        return parts.joined(separator: " · ")
    }

    var formatText: String {
        let ext = url.pathExtension.uppercased()
        if ext == "FLAC" || ext == "ALAC" {
            return bitDepth > 0 ? L10n.format("%@ %ld/%@", ext, bitDepth, sampleRateKHz) : ext
        }
        if sampleRate > 0 {
            return "\(ext) \(sampleRateKHz)"
        }
        return ext.isEmpty ? "AUDIO" : ext
    }

    /// Quality string for the progress bar and lists.
    var qualityText: String {
        var parts: [String] = [url.pathExtension.uppercased()]
        if bitDepth > 0, sampleRate > 0 {
            parts.append(L10n.format("%ld бит / %@", bitDepth, sampleRateKHz))
        } else if sampleRate > 0 {
            parts.append(sampleRateKHz)
        }
        if bitrate > 0 {
            parts.append(L10n.format("%ld кбит/с", bitrate / 1000))
        }
        return parts.joined(separator: " · ")
    }

    private var sampleRateKHz: String {
        let khz = sampleRate / 1000
        return khz == khz.rounded() ? L10n.format("%.0f кГц", khz) : L10n.format("%.1f кГц", khz)
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
        case .added: return L10n.string("По дате добавления")
        case .title: return L10n.string("По названию")
        case .artist: return L10n.string("По исполнителю")
        case .album: return L10n.string("По альбому")
        case .duration: return L10n.string("По длительности")
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

        // 1. Built-in parsers: FLAC (Vorbis + PICTURE) and ID3v2.
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
        if let genre = tags.genre, !genre.isEmpty { track.genre = genre }
        if let year = tags.year, !year.isEmpty { track.year = year }
        if let composer = tags.composer, !composer.isEmpty { track.composer = composer }
        if let disc = tags.discNumber { track.discNumber = disc }
        track.replayGainDB = tags.replayGainDB
        track.replayGainPeak = tags.replayGainPeak

        // 2. AVFoundation for what our parsers could not read (m4a/aac and others).
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


// MARK: - Encoding with artwork cache

extension Track {
    enum CodingKeys: String, CodingKey {
        case id, url, title, artist, album, albumArtist, trackNumber
        case genre, year, composer, discNumber, rating
        case duration, sampleRate, bitDepth, channels, bitrate
        case addedAt, artwork, artworkID, replayGainDB, replayGainPeak, cueStart, cueEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist) ?? ""
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        year = try container.decodeIfPresent(String.self, forKey: .year) ?? ""
        composer = try container.decodeIfPresent(String.self, forKey: .composer) ?? ""
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0
        rating = try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 0
        channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate) ?? 0
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        replayGainDB = try container.decodeIfPresent(Double.self, forKey: .replayGainDB)
        replayGainPeak = try container.decodeIfPresent(Double.self, forKey: .replayGainPeak)
        cueStart = try container.decodeIfPresent(TimeInterval.self, forKey: .cueStart)
        cueEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .cueEnd)
        artworkID = try container.decodeIfPresent(String.self, forKey: .artworkID)

        if let legacy = try container.decodeIfPresent(Data.self, forKey: .artwork), !legacy.isEmpty {
            artwork = legacy
            if artworkID == nil {
                artworkID = ArtworkCache.shared.store(legacy)
            }
        } else if let key = artworkID {
            artwork = ArtworkCache.shared.data(for: key)
        } else {
            artwork = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(albumArtist, forKey: .albumArtist)
        try container.encode(trackNumber, forKey: .trackNumber)
        try container.encode(genre, forKey: .genre)
        try container.encode(year, forKey: .year)
        try container.encode(composer, forKey: .composer)
        try container.encode(discNumber, forKey: .discNumber)
        try container.encode(rating, forKey: .rating)
        try container.encode(duration, forKey: .duration)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(bitDepth, forKey: .bitDepth)
        try container.encode(channels, forKey: .channels)
        try container.encode(bitrate, forKey: .bitrate)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(replayGainDB, forKey: .replayGainDB)
        try container.encodeIfPresent(replayGainPeak, forKey: .replayGainPeak)
        try container.encodeIfPresent(cueStart, forKey: .cueStart)
        try container.encodeIfPresent(cueEnd, forKey: .cueEnd)

        // Only the key goes into JSON; the bytes live in ArtworkCache.
        let identifier = artworkID ?? ArtworkCache.shared.store(artwork)
        try container.encodeIfPresent(identifier, forKey: .artworkID)
    }
}
