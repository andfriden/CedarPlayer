import SwiftUI

/// Engine reference without subscribing to its changes.
/// For views that only need actions: subscribing through
/// @EnvironmentObject would make a list of thousands of rows redraw
/// on every position update.
private struct PlayerEngineEnvironmentKey: EnvironmentKey {
    static let defaultValue: PlayerEngine? = nil
}

extension EnvironmentValues {
    var player: PlayerEngine? {
        get { self[PlayerEngineEnvironmentKey.self] }
        set { self[PlayerEngineEnvironmentKey.self] = newValue }
    }
}
