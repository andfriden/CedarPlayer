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

/// Рампа кроссфейда: старый трек уходит, новый приходит линейно.
enum Crossfade {
    static func outgoing(_ progress: Double) -> Float {
        Float(min(max(1 - progress, 0), 1))
    }

    static func incoming(_ progress: Double) -> Float {
        Float(min(max(progress, 0), 1))
    }
}
