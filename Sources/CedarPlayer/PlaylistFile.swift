import Foundation

/// Импорт и экспорт M3U/M3U8 и PLS.
enum PlaylistFile {
    enum Format: String, CaseIterable, Identifiable {
        case m3u
        case pls

        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var fileExtension: String { rawValue }
    }

    static let extensions: Set<String> = ["m3u", "m3u8", "pls"]

    static func isPlaylist(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Возвращает файлы плейлиста; относительные пути считаются от его каталога.
    static func parse(_ url: URL) -> [URL] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let base = url.deletingLastPathComponent()

        var entries: [URL] = []
        if url.pathExtension.lowercased() == "pls" {
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("file") else { continue }
                guard let separator = trimmed.firstIndex(of: "=") else { continue }
                entries.append(resolve(String(trimmed[trimmed.index(after: separator)...]), base: base))
            }
        } else {
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                entries.append(resolve(trimmed, base: base))
            }
        }

        var seen = Set<String>()
        return entries.filter { url in
            guard !url.path.isEmpty else { return false }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func resolve(_ raw: String, base: URL) -> URL {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("file://"), let url = URL(string: value) {
            return url
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return base.appendingPathComponent(value)
    }

    static func m3u(tracks: [Track]) -> String {
        var lines = ["#EXTM3U"]
        for track in tracks {
            let seconds = Int(track.duration.isFinite ? max(0, track.duration) : 0)
            let title = [track.displayArtist, track.displayTitle]
                .filter { !$0.isEmpty }
                .joined(separator: " - ")
            lines.append("#EXTINF:\(seconds),\(title)")
            lines.append(track.url.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func pls(tracks: [Track]) -> String {
        var lines = ["[playlist]", "Version=2", "NumberOfEntries=\(tracks.count)"]
        for (index, track) in tracks.enumerated() {
            let number = index + 1
            let seconds = Int(track.duration.isFinite ? max(0, track.duration) : 0)
            lines.append("File\(number)=\(track.url.path)")
            lines.append("Title\(number)=\(track.displayArtist) - \(track.displayTitle)")
            lines.append("Length\(number)=\(seconds)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
