import Foundation
import CWavPack

enum WavPackMetadata {
    static func read(url: URL) -> AudioTags? {
        guard let handle = url.path.withCString({ cwavpack_open($0) }) else { return nil }
        defer { cwavpack_close(handle) }

        var channels: Int32 = 0
        var rate: Int32 = 0
        var bits: Int32 = 0
        var frames: Int64 = 0
        var isFloat: Int32 = 0
        var isDSD: Int32 = 0
        guard cwavpack_info(handle, &channels, &rate, &bits, &frames, &isFloat, &isDSD) == 0 else {
            return nil
        }

        var tags = AudioTags()
        tags.channels = Int(channels)
        tags.sampleRate = Double(rate)
        tags.bitDepth = Int(bits)
        if rate > 0, frames > 0 { tags.duration = Double(frames) / Double(rate) }

        if let value = text(handle, keys: ["Title"]), !value.isEmpty { tags.title = value }
        if let value = text(handle, keys: ["Artist"]), !value.isEmpty { tags.artist = value }
        if let value = text(handle, keys: ["Album"]), !value.isEmpty { tags.album = value }
        if let value = text(handle, keys: ["Album Artist", "AlbumArtist"]), !value.isEmpty {
            tags.albumArtist = value
        }
        if let value = text(handle, keys: ["Track", "TrackNumber"]) {
            tags.trackNumber = Int(value.components(separatedBy: "/").first ?? "")
        }
        if let value = text(handle, keys: ["Disc", "DiscNumber"]) {
            tags.discNumber = Int(value.components(separatedBy: "/").first ?? "")
        }
        if let value = text(handle, keys: ["Genre"]), !value.isEmpty { tags.genre = value }
        if let value = text(handle, keys: ["Year", "Date"]), !value.isEmpty { tags.year = value }
        if let value = text(handle, keys: ["Composer"]), !value.isEmpty { tags.composer = value }
        if let value = text(handle, keys: ["replaygain_track_gain"]) {
            tags.replayGainDB = ReplayGain.parseGain(value)
        }
        if let value = text(handle, keys: ["replaygain_track_peak"]) {
            tags.replayGainPeak = ReplayGain.parsePeak(value)
        }
        return tags
    }

    private static func text(_ handle: OpaquePointer, keys: [String]) -> String? {
        for key in keys {
            let length = key.withCString { cwavpack_tag(handle, $0, nil, 0) }
            guard length > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(length) + 1)
            let copied = key.withCString {
                cwavpack_tag(handle, $0, &buffer, Int32(buffer.count))
            }
            guard copied > 0 else { continue }
            return String(cString: buffer)
        }
        return nil
    }
}
