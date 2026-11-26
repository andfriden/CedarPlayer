import Combine
import Foundation

/// Lightweight state for the "Управление" menu. Playback position and meters
/// update many times per second; observing PlayerEngine directly rebuilds the
/// menu and collapses its submenus while the user is hovering them.
@MainActor
final class PlayerMenuState: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var hasCurrentTrack = false
    @Published private(set) var isMuted = false
    @Published private(set) var isShuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var canUndoRemove = false
    @Published private(set) var isImporting = false

    private var isBound = false

    func bind(engine: PlayerEngine, library: Library) {
        guard !isBound else { return }
        isBound = true

        engine.$isPlaying
            .removeDuplicates()
            .assign(to: &$isPlaying)
        engine.$currentTrack
            .map { $0 != nil }
            .removeDuplicates()
            .assign(to: &$hasCurrentTrack)
        engine.$isMuted
            .removeDuplicates()
            .assign(to: &$isMuted)
        engine.$isShuffle
            .removeDuplicates()
            .assign(to: &$isShuffle)
        engine.$repeatMode
            .removeDuplicates()
            .assign(to: &$repeatMode)
        library.$canUndoRemove
            .removeDuplicates()
            .assign(to: &$canUndoRemove)
        library.$isImporting
            .removeDuplicates()
            .assign(to: &$isImporting)
    }
}

/// Owns the playback engine without forwarding its frequent objectWillChange
/// through the App scene, which would rebuild the menu bar commands.
@MainActor
final class PlayerServices: ObservableObject {
    let engine = PlayerEngine()
}
