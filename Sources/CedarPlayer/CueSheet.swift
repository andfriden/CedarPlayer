import Foundation

/// CUE parsing: one audio file is split into tracks by INDEX 01.
struct CueSheet {
    var title: String = ""
    var performer: String = ""
    var album: String = ""
    var genre: String = ""
    var date: String = ""
    var fileURL: URL
    var tracks: [CueTrackEntry] = []

    struct CueTrackEntry {
        var number: Int
        var title: String
        var performer: String
        var start: TimeInterval
        var end: TimeInterval?
    }
}

enum CueParser {

    static func parse(url: URL) -> CueSheet? {
        guard let text = try? String(contentsOf: url, encoding: .utf8)
                ?? String(contentsOf: url, encoding: .isoLatin1) else { return nil }

        var sheet: CueSheet?
        var current: CueSheet.CueTrackEntry?
        var globalTitle = ""
        var globalPerformer = ""
        var pendingFile: String?

        func finishTrack() {
            guard var track = current else { return }
            track.end = nil
            sheet?.tracks.append(track)
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = tokenize(line)
            guard let command = parts.first?.uppercased() else { continue }
            let arguments = Array(parts.dropFirst())

            switch command {
            case "REM":
                if arguments.count >= 2 {
                    let key = arguments[0].uppercased()
                    let value = arguments[1]
                    if key == "DATE" { sheet?.date = value }
                    if key == "GENRE" { sheet?.genre = value }
                }
            case "FILE":
                guard let name = arguments.first else { break }
                let audioURL = url.deletingLastPathComponent().appendingPathComponent(name)
                pendingFile = audioURL.path
                sheet = CueSheet(fileURL: audioURL)
            case "TRACK":
                finishTrack()
                let number = Int(arguments.first ?? "") ?? 0
                current = CueSheet.CueTrackEntry(number: number, title: "", performer: "", start: 0, end: nil)
            case "TITLE":
                let value = arguments.joined(separator: " ")
                if current != nil { current?.title = value } else { globalTitle = value }
            case "PERFORMER":
                let value = arguments.joined(separator: " ")
                if current != nil { current?.performer = value } else { globalPerformer = value }
            case "INDEX":
                guard arguments.count >= 2 else { break }
                let indexNumber = Int(arguments[0]) ?? 0
                if indexNumber == 1, let time = parseTime(arguments[1]) {
                    current?.start = time
                }
            default:
                break
            }
        }
        finishTrack()

        guard var result = sheet, !result.tracks.isEmpty else { return nil }
        result.title = globalTitle
        result.performer = globalPerformer
        if result.album.isEmpty { result.album = globalTitle }

        // Each track lasts until the next one starts.
        for index in result.tracks.indices {
            if index + 1 < result.tracks.count {
                result.tracks[index].end = result.tracks[index + 1].start
            }
        }
        _ = pendingFile
        return result
    }

    /// mm:ss:ff, where ff is frames at 1/75 second.
    static func parseTime(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count >= 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else { return nil }
        var frames = 0
        if parts.count >= 3 { frames = Int(parts[2]) ?? 0 }
        return TimeInterval(minutes * 60 + seconds) + TimeInterval(frames) / 75.0
    }

    private static func tokenize(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false
        for character in line {
            if character == "\"" {
                insideQuotes.toggle()
                continue
            }
            if character == " ", !insideQuotes {
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
