import SwiftUI

/// Ссылка на движок без подписки на его изменения.
/// Нужна видам, которым важны только действия: подписка через
/// @EnvironmentObject заставляла бы список из тысяч строк перерисовываться
/// на каждом обновлении позиции.
private struct PlayerEngineEnvironmentKey: EnvironmentKey {
    static let defaultValue: PlayerEngine? = nil
}

extension EnvironmentValues {
    var player: PlayerEngine? {
        get { self[PlayerEngineEnvironmentKey.self] }
        set { self[PlayerEngineEnvironmentKey.self] = newValue }
    }
}
