import Foundation

/// Плавное затухание в конце трека и нарастание в начале.
enum TransitionFade {
    /// Коэффициент громкости 0…1 для текущей позиции.
    static func factor(position: TimeInterval,
                       duration: TimeInterval,
                       fadeIn: TimeInterval,
                       fadeOut: TimeInterval) -> Float {
        guard duration > 0, position.isFinite else { return 1 }
        var value: Double = 1
        if fadeIn > 0, position < fadeIn {
            value = max(0, position / fadeIn)
        }
        if fadeOut > 0 {
            let remaining = duration - position
            if remaining < fadeOut {
                value = min(value, max(0, remaining / fadeOut))
            }
        }
        return Float(min(max(value, 0), 1))
    }
}
