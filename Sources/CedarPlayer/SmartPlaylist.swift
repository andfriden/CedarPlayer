import Foundation

/// Dynamic smart collections computed from the library on the fly.
enum SmartRule: String, CaseIterable, Identifiable {
    case favorites
    case recent
    case noArtwork
    case longTracks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "Любимые"
        case .recent: return "Недавно добавленные"
        case .noArtwork: return "Без обложки"
        case .longTracks: return "Длинные треки"
        }
    }

    var symbol: String {
        switch self {
        case .favorites: return "star.fill"
        case .recent: return "clock"
        case .noArtwork: return "photo"
        case .longTracks: return "timer"
        }
    }

    func matches(_ track: Track, now: Date = Date()) -> Bool {
        switch self {
        case .favorites:
            return track.rating >= 4
        case .recent:
            return now.timeIntervalSince(track.addedAt) <= 7 * 24 * 3600
        case .noArtwork:
            return track.artwork == nil
        case .longTracks:
            return track.duration >= 10 * 60
        }
    }

    func filter(_ tracks: [Track], now: Date = Date()) -> [Track] {
        tracks.filter { matches($0, now: now) }
    }
}
