import Foundation
import AppKit

struct CoverCandidate: Identifiable {
    let id = UUID()
    let imageData: Data
    let album: String
    let artist: String
    let source: String
}

enum CoverArtError: LocalizedError {
    case noQuery
    case noResults
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noQuery:
            return "Недостаточно данных: нужны исполнитель и альбом"
        case .noResults:
            return "Обложка не найдена"
        case .network(let message):
            return "Ошибка сети: \(message)"
        }
    }
}

/// Artwork search: iTunes Search API, fallback — MusicBrainz + Cover Art Archive.
actor CoverArtService {
    static let shared = CoverArtService()

    private let session: URLSession
    private var cache: [String: [CoverCandidate]] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func search(artist: String, album: String) async throws -> [CoverCandidate] {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty else { throw CoverArtError.noQuery }

        let key = "\(artist)|\(album)".lowercased()
        if let cached = cache[key], !cached.isEmpty { return cached }

        let source = ProcessInfo.processInfo.environment["CEDAR_COVER_SOURCE"]
        var results = source == "deezer" ? [] : ((try? await searchITunes(artist: artist, album: album)) ?? [])
        if results.isEmpty {
            results = (try? await searchDeezer(artist: artist, album: album)) ?? []
        }
        guard !results.isEmpty else { throw CoverArtError.noResults }
        cache[key] = results
        return results
    }

    // MARK: iTunes

    private struct ITunesResponse: Decodable {
        struct Item: Decodable {
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    private func searchITunes(artist: String, album: String) async throws -> [CoverCandidate] {
        let term = artist.isEmpty ? album : "\(artist) \(album)"
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CoverArtError.network("iTunes вернул \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)

        var candidates: [CoverCandidate] = []
        var seen = Set<String>()
        for item in decoded.results {
            guard let artwork = item.artworkUrl100, let base = URL(string: artwork) else { continue }
            let large = base.absoluteString
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
                .replacingOccurrences(of: "100x100", with: "600x600")
            guard seen.insert(large).inserted else { continue }
            guard let imageURL = URL(string: large),
                  let imageData = try? await download(imageURL),
                  NSImage(data: imageData) != nil else { continue }
            candidates.append(CoverCandidate(imageData: imageData,
                                             album: item.collectionName ?? album,
                                             artist: item.artistName ?? artist,
                                             source: "iTunes"))
            if candidates.count >= 6 { break }
        }
        return candidates
    }

    // MARK: Deezer (fallback)

    private struct DeezerResponse: Decodable {
        struct Album: Decodable {
            struct Artist: Decodable { let name: String? }
            let title: String?
            let artist: Artist?
            let cover_xl: String?
            let cover_big: String?
        }
        let data: [Album]?
    }

    private func searchDeezer(artist: String, album: String) async throws -> [CoverCandidate] {
        let term = artist.isEmpty ? album : "\(artist) \(album)"
        var components = URLComponents(string: "https://api.deezer.com/search/album")!
        components.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components.url else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CoverArtError.network("Deezer вернул \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let decoded = try JSONDecoder().decode(DeezerResponse.self, from: data)

        var candidates: [CoverCandidate] = []
        var seen = Set<String>()
        for item in decoded.data ?? [] {
            guard let cover = item.cover_xl ?? item.cover_big,
                  let imageURL = URL(string: cover),
                  seen.insert(cover).inserted else { continue }
            guard let imageData = try? await download(imageURL),
                  NSImage(data: imageData) != nil else { continue }
            candidates.append(CoverCandidate(imageData: imageData,
                                             album: item.title ?? album,
                                             artist: item.artist?.name ?? artist,
                                             source: "Deezer"))
            if candidates.count >= 6 { break }
        }
        return candidates
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("CedarPlayer/1.0 (https://github.com/andfriden/CedarPlayer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CoverArtError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
}
