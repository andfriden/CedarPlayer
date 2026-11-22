import Foundation

/// Analog VU calibration: 0 VU = −12 dBFS, scale −20…+3 VU.
/// −12 dBFS is a compromise for music: −20 dBFS pinned the needle to the right
/// on modern masters.
/// Position 0 is the left edge of the scale, 1 is the right.
enum VUCalibration {
    static let zeroVUdBFS: Double = -12

    /// Pairs of "VU value, label" in scale order.
    static let marks: [(vu: Double, label: String)] = [
        (-20, "-20"), (-10, "-10"), (-7, "-7"), (-5, "-5"),
        (-3, "-3"), (-1, "-1"), (0, "0"), (3, "+3")
    ]

    static var minVU: Double { marks.first?.vu ?? -20 }
    static var maxVU: Double { marks.last?.vu ?? 3 }

    /// Normalized engine level (0 = −60 dBFS, 1 = 0 dBFS) in dBFS.
    static func dBFS(fromLevel level: Double) -> Double {
        level * 60 - 60
    }

    static func vu(fromDBFS db: Double) -> Double {
        db - zeroVUdBFS
    }

    /// dBFS → needle position on the scale.
    static func position(forDBFS db: Double) -> Double {
        position(forVU: vu(fromDBFS: db))
    }

    static func position(forLevel level: Double) -> Double {
        position(forDBFS: dBFS(fromLevel: level))
    }

    /// Position for a VU value; linear interpolation between marks.
    static func position(forVU vu: Double) -> Double {
        let clamped = min(max(vu, minVU), maxVU)
        for index in 0..<(marks.count - 1) {
            let left = marks[index]
            let right = marks[index + 1]
            if clamped >= left.vu, clamped <= right.vu {
                let t = (clamped - left.vu) / (right.vu - left.vu)
                let leftPos = Double(index) / Double(marks.count - 1)
                let rightPos = Double(index + 1) / Double(marks.count - 1)
                return leftPos + t * (rightPos - leftPos)
            }
        }
        return clamped <= minVU ? 0 : 1
    }

    /// Inverse transform for the caption under the meter.
    static func vu(fromPosition position: Double) -> Double {
        let clamped = min(max(position, 0), 1)
        let scaled = clamped * Double(marks.count - 1)
        let index = min(Int(scaled), marks.count - 2)
        let t = scaled - Double(index)
        let left = marks[index].vu
        let right = marks[index + 1].vu
        return left + t * (right - left)
    }
}
