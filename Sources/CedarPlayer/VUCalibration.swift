import Foundation

/// Калибровка стрелочного VU: 0 VU = −12 dBFS, шкала −20…+3 VU.
/// −12 dBFS выбран как компромисс для музыки: −20 dBFS «вешало» стрелку вправо
/// на современных мастерингах.
/// Позиция 0 — левый край шкалы, 1 — правый.
enum VUCalibration {
    static let zeroVUdBFS: Double = -12

    /// Пары «значение VU, подпись» в порядке шкалы.
    static let marks: [(vu: Double, label: String)] = [
        (-20, "-20"), (-10, "-10"), (-7, "-7"), (-5, "-5"),
        (-3, "-3"), (-1, "-1"), (0, "0"), (3, "+3")
    ]

    static var minVU: Double { marks.first?.vu ?? -20 }
    static var maxVU: Double { marks.last?.vu ?? 3 }

    /// Нормированный уровень движка (0 = −60 dBFS, 1 = 0 dBFS) в dBFS.
    static func dBFS(fromLevel level: Double) -> Double {
        level * 60 - 60
    }

    static func vu(fromDBFS db: Double) -> Double {
        db - zeroVUdBFS
    }

    /// dBFS → положение стрелки на шкале.
    static func position(forDBFS db: Double) -> Double {
        position(forVU: vu(fromDBFS: db))
    }

    static func position(forLevel level: Double) -> Double {
        position(forDBFS: dBFS(fromLevel: level))
    }

    /// Положение по значению VU; между рисками — линейная интерполяция.
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

    /// Обратное преобразование для подписи под прибором.
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
