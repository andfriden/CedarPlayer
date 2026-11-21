import Foundation

/// ReplayGain: значение из тегов и безопасный коэффициент усиления.
enum ReplayGain {
    /// Верхняя граница буста, чтобы не выкручивать тихие записи в клиппинг.
    static let maxBoostDB: Double = 6
    static let minGainDB: Double = -24

    /// "-7.23 dB" → -7.23. Понимает запятую и знак плюс.
    static func parseGain(_ value: String) -> Double? {
        let trimmed = value
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        return Double(trimmed)
    }

    static func parsePeak(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces))
    }

    /// Итоговое усиление в дБ с учётом пика.
    static func effectiveDB(trackGainDB: Double?, peak: Double?) -> Double {
        guard let gain = trackGainDB, gain.isFinite else { return 0 }
        var db = min(max(gain, minGainDB), maxBoostDB)
        if let peak, peak > 0.0001 {
            db = min(db, 20 * log10(1 / peak))
        }
        return db
    }

    /// Коэффициент усиления (для проверок и отображения).
    static func factor(trackGainDB: Double?, peak: Double?) -> Float {
        Float(pow(10, effectiveDB(trackGainDB: trackGainDB, peak: peak) / 20))
    }

    static func text(_ gain: Double) -> String {
        String(format: "%+.1f дБ", gain)
    }
}
