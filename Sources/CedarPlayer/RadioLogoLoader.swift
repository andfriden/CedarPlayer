import Foundation
import AppKit

/// Ищет логотип станции: указанный URL, затем favicon и типовые иконки хоста.
enum RadioLogoLoader {
    static func candidates(for station: RadioStation) -> [URL] {
        var urls: [URL] = []
        if let custom = station.logoURLString,
           let url = URL(string: custom.trimmingCharacters(in: .whitespacesAndNewlines)) {
            urls.append(url)
        }
        guard let host = station.url?.host else { return urls }
        let scheme = station.url?.scheme == "http" ? "http" : "https"
        for path in ["/apple-touch-icon.png", "/favicon.ico", "/logo.png"] {
            if let url = URL(string: "\(scheme)://\(host)\(path)") {
                urls.append(url)
            }
        }
        return urls
    }

    static func load(_ station: RadioStation) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)

        for url in candidates(for: station) {
            var request = URLRequest(url: url)
            request.setValue("CedarPlayer/1.0", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 64,
                  NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }
}
