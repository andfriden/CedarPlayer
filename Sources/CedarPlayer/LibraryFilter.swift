import Foundation

enum LibraryQuality: String, CaseIterable, Identifiable {
    case hiRes
    case lossless
    case dsd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hiRes: return "Hi-Res"
        case .lossless: return L10n.string("Без потерь")
        case .dsd: return "DSD"
        }
    }

    func matches(_ track: Track) -> Bool {
        switch self {
        case .hiRes:
            return track.sampleRate > 48_000 || track.bitDepth > 16
        case .lossless:
            return ["flac", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf", "ape", "wv", "tta"]
                .contains(track.url.pathExtension.lowercased())
        case .dsd:
            return ["dsf", "dff"].contains(track.url.pathExtension.lowercased())
        }
    }
}

struct LibraryFilter: Equatable {
    var genre: String?
    var year: String?
    var format: String?
    var quality: LibraryQuality?
    var onlyMissing = false
    var onlyWithArtwork = false

    var isActive: Bool {
        genre != nil || year != nil || format != nil || quality != nil || onlyMissing || onlyWithArtwork
    }

    func apply(to tracks: [Track]) -> [Track] {
        guard isActive else { return tracks }
        return tracks.filter { track in
            if let genre, track.genre.caseInsensitiveCompare(genre) != .orderedSame { return false }
            if let year, track.year != year { return false }
            if let format, track.url.pathExtension.caseInsensitiveCompare(format) != .orderedSame { return false }
            if let quality, !quality.matches(track) { return false }
            if onlyMissing, !track.isMissing { return false }
            if onlyWithArtwork, track.artwork == nil { return false }
            return true
        }
    }
}
