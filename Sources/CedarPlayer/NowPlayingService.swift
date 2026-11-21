import Foundation
import AppKit
import Combine
import MediaPlayer

/// Отдаёт состояние плеера системе: Now Playing в Пункте управления и медиа-клавиши.
@MainActor
final class NowPlayingService {

    static let shared = NowPlayingService()

    private weak var engine: PlayerEngine?
    private var cancellables = Set<AnyCancellable>()
    private var commandsConfigured = false
    private var artworkKey: String?
    private var artworkValue: MPMediaItemArtwork?

    private init() {}

    /// Подписывается на движок один раз и настраивает обработчики пульта.
    func attach(_ engine: PlayerEngine) {
        guard self.engine !== engine else { return }
        self.engine = engine
        configureCommands()

        engine.$currentTrack
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshNow() }
            }
            .store(in: &cancellables)
        engine.$isPlaying
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshRate() }
            }
            .store(in: &cancellables)
        engine.$position
            .sink { [weak self] position in
                Task { @MainActor [weak self] in self?.updateElapsed(position) }
            }
            .store(in: &cancellables)
        engine.$duration
            .sink { [weak self] duration in
                Task { @MainActor [weak self] in self?.updateDuration(duration) }
            }
            .store(in: &cancellables)
        engine.$radioNowPlaying
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshNow() }
            }
            .store(in: &cancellables)
        engine.$playbackRate
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshRate() }
            }
            .store(in: &cancellables)

        refreshNow()
    }

    /// Полностью пересобирает словарь Now Playing (трек, очередь, обложка).
    func refreshNow() {
        let center = MPNowPlayingInfoCenter.default()
        if let engine, let station = engine.currentStation {
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: station.name,
                MPMediaItemPropertyArtist: engine.radioNowPlaying ?? "Онлайн-радио",
                MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0
            ]
            center.playbackState = engine.isPlaying ? .playing : .paused
            return
        }
        guard let engine, let track = engine.currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyPlaybackDuration: max(engine.duration, track.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.position,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? engine.playbackRate : 0.0
        ]
        if !track.artist.isEmpty { info[MPMediaItemPropertyArtist] = track.artist }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if !track.albumArtist.isEmpty { info[MPMediaItemPropertyAlbumArtist] = track.albumArtist }
        if track.trackNumber > 0 { info[MPMediaItemPropertyAlbumTrackNumber] = track.trackNumber }
        if engine.queueIndex >= 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = engine.queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = engine.queue.count
        }
        if let artwork = mediaArtwork(for: track) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        center.nowPlayingInfo = info
        center.playbackState = engine.isPlaying ? .playing : .paused
    }

    // MARK: Обновления по частям

    private func refreshRate() {
        guard let engine else { return }
        if engine.currentStation != nil {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = engine.isPlaying ? .playing : .paused
            return
        }
        guard engine.currentTrack != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPlaying ? engine.playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = engine.isPlaying ? .playing : .paused
    }

    private func updateElapsed(_ position: TimeInterval) {
        guard engine?.currentTrack != nil,
              var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateDuration(_ duration: TimeInterval) {
        guard duration > 0,
              engine?.currentTrack != nil,
              var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func mediaArtwork(for track: Track) -> MPMediaItemArtwork? {
        guard let data = track.artwork else { return nil }
        let key = track.artworkID ?? "\(track.url.path)#\(data.count)"
        if artworkKey == key, let artworkValue { return artworkValue }
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        let value = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        artworkKey = key
        artworkValue = value
        return value
    }

    // MARK: Пульт и медиа-клавиши

    private func configureCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.play() }
            return self == nil ? .noSuchContent : .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.pause() }
            return self == nil ? .noSuchContent : .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.toggle() }
            return self == nil ? .noSuchContent : .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.next(manual: true) }
            return self == nil ? .noSuchContent : .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.previous() }
            return self == nil ? .noSuchContent : .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in self?.engine?.seek(to: target) }
            return self == nil ? .noSuchContent : .success
        }

        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.pause() }
            return self == nil ? .noSuchContent : .success
        }

        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
    }
}
