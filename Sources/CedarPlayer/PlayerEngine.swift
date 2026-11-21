import Foundation
import AVFoundation
import Combine

/// Движок воспроизведения: AVAudioEngine + узел эквалайзера + регулировка скорости.
/// Реализация собственная, сторонние плееры не используются.
@MainActor
final class PlayerEngine: ObservableObject {

    // MARK: Состояние

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentStation: RadioStation?
    private var radioPlayer: AVPlayer?

    /// Подменяет метаданные играющего трека после правки тегов.
    func syncCurrentTrack(with track: Track) {
        guard let current = currentTrack, current.id == track.id else { return }
        currentTrack = track
        applyReplayGain()
    }

    /// Выравнивание громкости по ReplayGain: отдельный EQ-узел в 0 полос.
    private func applyReplayGain() {
        guard isReplayGainEnabled, let track = currentTrack else {
            replayGainNode.globalGain = 0
            return
        }
        replayGainNode.globalGain = Float(ReplayGain.effectiveDB(trackGainDB: track.replayGainDB,
                                                                peak: track.replayGainPeak))
    }

    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var volume: Double = 0.8 {
        didSet {
            engine.mainMixerNode.outputVolume = Float(volume)
            radioPlayer?.volume = Float(isMuted ? 0 : volume)
        }
    }
    @Published var isMuted = false {
        didSet {
            engine.mainMixerNode.outputVolume = isMuted ? 0 : Float(volume)
            radioPlayer?.volume = Float(isMuted ? 0 : volume)
        }
    }
    @Published var isShuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackRate: Double = 1.0 {
        didSet { timePitch.rate = Float(playbackRate) }
    }
    @Published var isEQEnabled = false {
        didSet { applyEQState(); persistEQ() }
    }
    @Published var preamp: Double = 0 {
        didSet { applyEQState(); persistEQ() }
    }
    @Published var bands: [Double] = Array(repeating: 0, count: 10) {
        didSet { applyBands(); persistEQ() }
    }
    /// Плавное затухание в конце и нарастание в начале трека.
    @Published var transitionFadeSeconds: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(transitionFadeSeconds, forKey: "transitionFadeSeconds")
            applyFade()
        }
    }

    @Published var isReplayGainEnabled = false {
        didSet {
            UserDefaults.standard.set(isReplayGainEnabled, forKey: "replayGainEnabled")
            applyReplayGain()
        }
    }
    @Published var errorMessage: String?
    @Published private(set) var usesDSPEqualizer = false

    @Published private(set) var spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    @Published private(set) var spectrumPeaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    let spectrumAnalyzer = SpectrumAnalyzer()
    let levelMeter = LevelMeter()
    @Published private(set) var levelL: Float = 0
    @Published private(set) var levelR: Float = 0
    @Published private(set) var peakL: Float = 0
    @Published private(set) var peakR: Float = 0

    let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: Очередь

    private(set) var queue: [Track] = []
    private(set) var queueIndex: Int = -1

    // MARK: Аудиограф

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var equalizer: AVAudioUnit!
    private var biquad: BiquadEQAudioUnit?
    private let replayGainNode: AVAudioUnitEQ = {
        // Ноль полос у AVAudioUnitEQ не обрабатывает globalGain, поэтому одна
        // выключенная полоса — узел остаётся активным и усиливает сигнал.
        let node = AVAudioUnitEQ(numberOfBands: 1)
        node.bands[0].filterType = .parametric
        node.bands[0].frequency = 1000
        node.bands[0].bandwidth = 2
        node.bands[0].gain = 0
        node.bands[0].bypass = false
        return node
    }()
    private let timePitch = AVAudioUnitTimePitch()

    private var file: AVAudioFile?
    private var sampleRate: Double = 44100
    private var totalFrames: AVAudioFramePosition = 0
    private var startFrame: AVAudioFramePosition = 0
    private var endFrame: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?

    init() {
        isReplayGainEnabled = UserDefaults.standard.bool(forKey: "replayGainEnabled")
        transitionFadeSeconds = UserDefaults.standard.object(forKey: "transitionFadeSeconds") as? Double ?? 1.0
        loadEQSettings()
        configureGraph()
        startTimer()
        levelMeter.onUpdate = { [weak self] reading in
            guard let self else { return }
            Task { @MainActor in
                self.levelL = reading.rms[0]
                self.levelR = reading.rms[1]
                self.peakL = reading.peaks[0]
                self.peakR = reading.peaks[1]
            }
        }

        spectrumAnalyzer.onUpdate = { [weak self] bands, peaks in
            guard let self else { return }
            Task { @MainActor in
                self.spectrum = bands
                self.spectrumPeaks = peaks
            }
        }
    }

    private func configureGraph() {
        if let node = BiquadEQAudioUnit.makeNode(),
           let unit = node.auAudioUnit as? BiquadEQAudioUnit {
            equalizer = node
            biquad = unit
            usesDSPEqualizer = true
        } else {
            let fallback = AVAudioUnitEQ(numberOfBands: 10)
            for (index, frequency) in frequencies.enumerated() {
                let band = fallback.bands[index]
                band.filterType = .parametric
                band.frequency = Float(frequency)
                band.bandwidth = 1.0
                band.gain = 0
                band.bypass = false
            }
            fallback.globalGain = 0
            equalizer = fallback
        }

        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(equalizer)
        engine.attach(replayGainNode)
        applyEQState()
        applyBands()

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: replayGainNode, format: format)
        engine.connect(replayGainNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(volume)

        do {
            try engine.start()
        } catch {
            errorMessage = "Звуковое устройство недоступно: \(error.localizedDescription)"
        }

        let analyzer = spectrumAnalyzer
        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let meter = levelMeter
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: tapFormat) { buffer, _ in
            analyzer.process(buffer)
            meter.process(buffer)
        }
    }

    private var isRestoringEQ = false

    private func loadEQSettings() {
        isRestoringEQ = true
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "eqEnabled") != nil {
            isEQEnabled = defaults.bool(forKey: "eqEnabled")
        }
        if defaults.object(forKey: "eqPreamp") != nil {
            preamp = defaults.double(forKey: "eqPreamp")
        }
        if let raw = defaults.array(forKey: "eqBands"), raw.count == 10 {
            let saved = raw.map { element -> Double in
                if let value = element as? Double { return value }
                if let value = element as? Int { return Double(value) }
                if let value = element as? NSNumber { return value.doubleValue }
                if let value = element as? String, let parsed = Double(value) { return parsed }
                return 0
            }
            bands = saved
        }
        isRestoringEQ = false
    }

    private func persistEQ() {
        guard !isRestoringEQ else { return }
        let defaults = UserDefaults.standard
        defaults.set(isEQEnabled, forKey: "eqEnabled")
        defaults.set(preamp, forKey: "eqPreamp")
        defaults.set(bands, forKey: "eqBands")
    }

    private func applyEQState() {
        guard let equalizer else { return }
        if let biquad {
            biquad.setEnabled(isEQEnabled)
            biquad.setPreamp(preamp)
        } else if let legacy = equalizer as? AVAudioUnitEQ {
            legacy.bypass = !isEQEnabled
            legacy.globalGain = isEQEnabled ? Float(preamp) : 0
        }
    }

    private func applyBands() {
        guard let equalizer else { return }
        if let biquad {
            biquad.setBands(bands, frequencies: frequencies)
        } else if let legacy = equalizer as? AVAudioUnitEQ {
            for (index, gain) in bands.enumerated() where index < legacy.bands.count {
                legacy.bands[index].gain = Float(gain)
            }
        }
    }

    // MARK: Загрузка

    func setQueue(_ tracks: [Track], startAt index: Int, autoplay: Bool = true) {
        queue = tracks
        queueIndex = index
        guard tracks.indices.contains(index) else { return }
        load(tracks[index], autoplay: autoplay)
    }

    func load(_ track: Track, autoplay: Bool) {
        stopRadioPlayback()
        do {
            let newFile = try AVAudioFile(forReading: track.url)
            let format = newFile.processingFormat

            generation += 1
            player.stop()
            engine.stop()

            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.disconnectNodeOutput(equalizer)
            engine.disconnectNodeOutput(replayGainNode)

            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: equalizer, format: format)
            engine.connect(equalizer, to: replayGainNode, format: format)
            engine.connect(replayGainNode, to: engine.mainMixerNode, format: format)

            try engine.start()

            file = newFile
            sampleRate = format.sampleRate
            totalFrames = newFile.length
            let fileDuration = sampleRate > 0 ? Double(totalFrames) / sampleRate : track.duration
            let segmentStart = max(0, min(track.cueStart ?? 0, fileDuration))
            let segmentEnd = max(segmentStart, min(track.cueEnd ?? fileDuration, fileDuration))
            startFrame = AVAudioFramePosition((segmentStart * sampleRate).rounded())
            endFrame = min(totalFrames,
                           max(startFrame + 1, AVAudioFramePosition((segmentEnd * sampleRate).rounded())))
            seekFrame = startFrame
            duration = sampleRate > 0 ? Double(endFrame - startFrame) / sampleRate : track.duration
            spectrumAnalyzer.configure(sampleRate: sampleRate)
            spectrumAnalyzer.reset()
            levelMeter.reset()
            position = 0
            currentTrack = track
            applyReplayGain()
            errorMessage = nil

            if autoplay { play() }
        } catch {
            player.stop()
            isPlaying = false
            currentTrack = track
            duration = track.duration
            errorMessage = "Файл не поддерживается или повреждён: \(track.url.lastPathComponent)"
        }
    }

    // MARK: Радио

    /// Запускает интернет-станцию через AVPlayer; локальная очередь останавливается.
    func playRadio(_ station: RadioStation) {
        guard let url = station.url else {
            errorMessage = "Некорректный адрес станции"
            return
        }
        player.stop()
        file = nil
        isPlaying = false
        position = 0
        duration = 0
        currentTrack = nil
        errorMessage = nil
        currentStation = station

        let avPlayer = AVPlayer(playerItem: AVPlayerItem(url: url))
        avPlayer.volume = Float(isMuted ? 0 : volume)
        radioPlayer = avPlayer
        avPlayer.play()
        isPlaying = true
    }

    private func stopRadioPlayback() {
        radioPlayer?.pause()
        radioPlayer = nil
        currentStation = nil
    }

    // MARK: Управление

    func play() {
        if let radioPlayer {
            radioPlayer.play()
            isPlaying = true
            return
        }
        guard file != nil else { return }
        if player.isPlaying { return }
        if !engine.isRunning {
            try? engine.start()
        }
        scheduleFromCurrentFrame()
        player.volume = 1
        player.play()
        isPlaying = true
        applyFade()
    }

    func pause() {
        if let radioPlayer {
            radioPlayer.pause()
            isPlaying = false
            return
        }
        guard player.isPlaying else { return }
        seekFrame = currentFrame()
        player.pause()
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func stop() {
        if radioPlayer != nil {
            stopRadioPlayback()
            isPlaying = false
            return
        }
        player.stop()
        isPlaying = false
        seekFrame = startFrame
        position = 0
    }

    func seek(to seconds: TimeInterval) {
        guard currentStation == nil, file != nil, sampleRate > 0 else { return }
        let clamped = max(0, min(seconds, duration))
        let frame = min(endFrame, startFrame + AVAudioFramePosition((clamped * sampleRate).rounded()))
        seekFrame = frame
        position = clamped
        if player.isPlaying { player.volume = 1 }

        if player.isPlaying {
            let wasPlaying = isPlaying
            player.stop()
            isPlaying = false
            if wasPlaying { play() }
        }
    }

    func next(manual: Bool = false) {
        if currentStation != nil {
            stop()
            if queue.indices.contains(queueIndex) { play(at: queueIndex) }
            return
        }
        guard !queue.isEmpty else { return }
        if repeatMode == .one && !manual {
            seek(to: 0)
            play()
            return
        }
        var nextIndex = queueIndex + 1
        if isShuffle {
            if queue.count > 1 {
                var candidate = queueIndex
                while candidate == queueIndex { candidate = Int.random(in: 0..<queue.count) }
                nextIndex = candidate
            }
        } else if nextIndex >= queue.count {
            if repeatMode == .all {
                nextIndex = 0
            } else {
                stop()
                return
            }
        }
        queueIndex = nextIndex
        load(queue[nextIndex], autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if position > 3.0 {
            seek(to: 0)
            return
        }
        var previousIndex = queueIndex - 1
        if previousIndex < 0 { previousIndex = repeatMode == .all ? queue.count - 1 : 0 }
        queueIndex = previousIndex
        load(queue[previousIndex], autoplay: true)
    }

    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queueIndex = index
        load(queue[index], autoplay: true)
    }

    func currentIndex() -> Int? { queueIndex >= 0 ? queueIndex : nil }

    // MARK: Планирование сегмента

    private func scheduleFromCurrentFrame() {
        guard let file else { return }
        let remaining = endFrame - seekFrame
        guard remaining > 0 else { return }

        generation += 1
        let token = generation

        player.scheduleSegment(
            file,
            startingFrame: seekFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.handleTrackEnd()
            }
        }
    }

    private func handleTrackEnd() {
        guard isPlaying || position >= duration - 0.5 else { return }
        if repeatMode == .one {
            seekFrame = startFrame
            position = 0
            scheduleFromCurrentFrame()
            player.play()
            isPlaying = true
        } else {
            next()
        }
    }

    /// Пересчитывает громкость по позиции: мягкий вход и выход без щелчков.
    private func applyFade() {
        guard file != nil, isPlaying, player.isPlaying else { return }
        let fade = max(0, transitionFadeSeconds)
        player.volume = TransitionFade.factor(position: position,
                                              duration: duration,
                                              fadeIn: min(0.4, fade),
                                              fadeOut: fade)
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return seekFrame }
        return min(endFrame, seekFrame + playerTime.sampleTime)
    }

    // MARK: Таймер позиции

    private var tick = 0

    private func persistPlaybackState() {
        guard let track = currentTrack else { return }
        let defaults = UserDefaults.standard
        defaults.set(track.id.uuidString, forKey: "lastTrackID")
        defaults.set(position, forKey: "lastPosition")
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, self.currentStation == nil, self.sampleRate > 0 else { return }
                let played = Double(self.currentFrame() - self.startFrame) / self.sampleRate
                self.position = min(self.duration, max(0, played))
                self.applyFade()
                self.tick += 1
                if self.tick % 10 == 0 { self.persistPlaybackState() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: Эквалайзер

    struct EQPreset: Identifiable, Hashable {
        let name: String
        let gains: [Double]
        let preamp: Double
        var id: String { name }
    }

    static let presets: [EQPreset] = [
        .init(name: "Flat", gains: Array(repeating: 0, count: 10), preamp: 0),
        .init(name: "Rock", gains: [5, 4, 2, -1, -2, -1, 2, 4, 5, 5], preamp: -3),
        .init(name: "Pop", gains: [-1, 1, 3, 4, 3, 1, -1, -1, 1, 2], preamp: -2),
        .init(name: "Jazz", gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3], preamp: -2),
        .init(name: "Classical", gains: [4, 3, 2, 1, 0, 0, 1, 2, 3, 4], preamp: -3),
        .init(name: "Vocal", gains: [-3, -2, 0, 2, 4, 4, 3, 1, 0, -1], preamp: -2),
        .init(name: "Bass Boost", gains: [8, 7, 5, 3, 1, 0, 0, 0, 0, 0], preamp: -5),
        .init(name: "Treble", gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7], preamp: -4),
        .init(name: "Loudness", gains: [6, 4, 0, -2, -3, -1, 2, 4, 6, 7], preamp: -5)
    ]

    func apply(preset: EQPreset) {
        preamp = preset.preamp
        bands = preset.gains
        if !isEQEnabled { isEQEnabled = true }
    }

    func resetEQ() {
        preamp = 0
        bands = Array(repeating: 0, count: 10)
    }
}
