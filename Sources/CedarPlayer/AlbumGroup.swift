import Foundation

/// Альбом как группа треков с общей обложкой — для сетки в окне библиотеки.
struct AlbumGroup: Identifiable, Hashable {
    struct Key: Hashable {
        let album: String
        let albumArtist: String
    }

    let key: Key
    let tracks: [Track]

    var id: String { "\(key.album)|\(key.albumArtist)" }

    var title: String { key.album.isEmpty ? "Без альбома" : key.album }

    var artist: String {
        if !key.albumArtist.isEmpty { return key.albumArtist }
        return tracks.first?.displayArtist ?? ""
    }

    var artwork: Data? {
        tracks.first { $0.artwork != nil }?.artwork
    }

    var duration: TimeInterval {
        tracks.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) }
    }

    /// Группирует треки по альбому и исполнителю альбома, сортирует альбомы по названию.
    static func group(_ tracks: [Track]) -> [AlbumGroup] {
        var order: [Key] = []
        var buckets: [Key: [Track]] = [:]

        for track in tracks {
            let albumArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            let key = Key(album: track.album, albumArtist: albumArtist)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(track)
        }

        return order.map { key in
            let sorted = (buckets[key] ?? []).sorted { lhs, rhs in
                if lhs.trackNumber != rhs.trackNumber {
                    return lhs.trackNumber < rhs.trackNumber
                }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
            return AlbumGroup(key: key, tracks: sorted)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
