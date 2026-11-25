import Foundation

struct LRCLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

enum LRCParser {
    private static let timestamp = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let offset = try! NSRegularExpression(
        pattern: #"^\[offset:\s*([+-]?\d+)\]\s*$"#, options: .caseInsensitive)

    static func parse(_ source: String) -> [LRCLine] {
        var rows: [(time: TimeInterval, text: String)] = []
        var offsetSeconds: TimeInterval = 0

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = offset.firstMatch(in: line, range: range),
               let valueRange = Range(match.range(at: 1), in: line),
               let value = Int(line[valueRange]) {
                offsetSeconds = TimeInterval(value) / 1000
                continue
            }

            let matches = timestamp.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }
            let text = timestamp.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minuteRange]),
                      let seconds = Double(line[secondRange]) else { continue }
                var fraction: Double = 0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = line[fractionRange]
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                rows.append((minutes * 60 + seconds + fraction, text))
            }
        }

        return rows.sorted { $0.time < $1.time }
            .enumerated()
            .map { LRCLine(id: $0.offset,
                           time: max(0, $0.element.time + offsetSeconds),
                           text: $0.element.text) }
    }
}
