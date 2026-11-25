import Foundation

enum LyricsError: LocalizedError {
    case noQuery
    case notFound
    case instrumental
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noQuery:
            return L10n.string("Недостаточно данных для поиска текста")
        case .notFound:
            return L10n.string("Текст не найден")
        case .instrumental:
            return L10n.string("Это инструментальная композиция")
        case .network(let message):
            return L10n.format("Ошибка сети: %@", message)
        }
    }
}

/// Downloads synchronized lyrics from LRCLIB.
actor LyricsService {
    static let shared = LyricsService()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func download(title: String, artist: String, album: String,
                  duration: TimeInterval) async throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { throw LyricsError.noQuery }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !album.isEmpty { query.append(URLQueryItem(name: "album_name", value: album)) }
        if duration >= 1, duration <= 3600 {
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = query
        guard let url = components.url else { throw LyricsError.noQuery }

        var request = URLRequest(url: url)
        request.setValue("Cedar Player/1.0 (https://github.com/andfriden/CedarPlayer)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LyricsError.network(L10n.string("Нет ответа"))
        }
        if http.statusCode == 404 { throw LyricsError.notFound }
        guard http.statusCode == 200 else {
            let retry = http.value(forHTTPHeaderField: "Retry-After")
            let suffix = retry.map { L10n.format(" (повтор через %@ с)", $0) } ?? ""
            throw LyricsError.network(L10n.format("LRCLIB вернул %ld%@", http.statusCode, suffix))
        }

        struct Response: Decodable {
            let instrumental: Bool?
            let plainLyrics: String?
            let syncedLyrics: String?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if decoded.instrumental == true { throw LyricsError.instrumental }
        let lyrics = [decoded.syncedLyrics, decoded.plainLyrics]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let lyrics else { throw LyricsError.notFound }
        return lyrics
    }
}
