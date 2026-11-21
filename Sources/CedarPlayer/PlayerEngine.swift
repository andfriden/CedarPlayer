import Foundation
import AVFoundation
import AudioToolbox
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
    private var icyReader: IcyMetadataReader?
    private var radioItemObservation: NSKeyValueObservation?
    private var radioTimeObservation: NSKeyValueObservation?
    private var radioRetryWork: DispatchWorkItem?
    private var radioRetryAttempts = 0
    @Published private(set) var radioBuffering = false
    @Published private(set) var radioNowPlaying: String?

    // MARK: Устройство вывода

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var selectedOutputUID: String?
    @Published private(set) var outputFormatDescription = "—"

    /// Истинный кроссфейд: наложение следующего трека на последние секунды текущего.
    @Published var crossfadeSeconds: Double = 0 {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: "crossfadeSeconds") }
    }
    @Published private(set) var radioArtist: String?
    @Published private(set) var radioTrack: String?

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
    @Published private(set) var rawLevelL: Float = 0
    @Published private(set) var rawLevelR: Float = 0
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
    private let fadePlayer = AVAudioPlayerNode()
    private let blendMixer = AVAudioMixerNode()
    private var activeNode: AVAudioPlayerNode!
    private var idleNode: AVAudioPlayerNode { activeNode === player ? fadePlayer : player }
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
        activeNode = player
        isReplayGainEnabled = UserDefaults.standard.bool(forKey: "replayGainEnabled")
        crossfadeSeconds = UserDefaults.standard.object(forKey: "crossfadeSeconds") as? Double ?? 0
        transitionFadeSeconds = UserDefaults.standard.object(forKey: "transitionFadeSeconds") as? Double ?? 1.0
        loadEQSettings()
        configureGraph()
        restoreOutputDevice()
        startTimer()
        levelMeter.onUpdate = { [weak self] reading in
            guard let self else { return }
            Task { @MainActor in
                self.levelL = reading.rms[0]
                self.levelR = reading.rms[1]
                self.peakL = reading.peaks[0]
                self.peakR = reading.peaks[1]
                self.rawLevelL = reading.raw[0]
                self.rawLevelR = reading.raw[1]
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
        engine.attach(fadePlayer)
        engine.attach(blendMixer)
        engine.attach(timePitch)
        engine.attach(equalizer)
        engine.attach(replayGainNode)
        applyEQState()
        applyBands()

        // Оба плеера входят в общий микшер, дальше одна цепочка обработки.
        engine.connect(player, to: blendMixer, format: nil)
        engine.connect(fadePlayer, to: blendMixer, format: nil)
        engine.connect(blendMixer, to: timePitch, format: nil)
        engine.connect(timePitch, to: equalizer, format: nil)
        engine.connect(equalizer, to: replayGainNode, format: nil)
        engine.connect(replayGainNode, to: engine.mainMixerNode, format: nil)
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
            cancelCrossfade()
            player.stop()
            fadePlayer.stop()
            activeNode = player
            activeNode.volume = 1

            if !engine.isRunning {
                try engine.start()
            }

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
            activeNode.stop()
            isPlaying = false
            currentTrack = track
            duration = track.duration
            errorMessage = "Файл не поддерживается или повреждён: \(track.url.lastPathComponent)"
        }
    }

    // MARK: Устройство вывода

    /// Перечитывает список устройств; выбранное сохраняется, если ещё доступно.
    func refreshOutputDevices() {
        outputDevices = AudioDevices.outputs()
        if let uid = selectedOutputUID, outputDevices.contains(where: { $0.id == uid }) {
            updateOutputFormat()
        } else {
            selectedOutputUID = AudioDevices.defaultOutputUID ?? outputDevices.first?.id
            updateOutputFormat()
        }
    }

    func selectOutput(uid: String) {
        guard uid != selectedOutputUID else { return }
        applyOutput(uid: uid, persist: true)
    }

    private func restoreOutputDevice() {
        outputDevices = AudioDevices.outputs()
        let saved = UserDefaults.standard.string(forKey: "outputDeviceUID")
        if let saved, outputDevices.contains(where: { $0.id == saved }) {
            selectedOutputUID = saved
        } else {
            selectedOutputUID = AudioDevices.defaultOutputUID ?? outputDevices.first?.id
        }
        updateOutputFormat()
    }

    private func applyOutput(uid: String, persist: Bool) {
        guard let deviceID = AudioDevices.deviceID(forUID: uid),
              let audioUnit = engine.outputNode.audioUnit else { return }

        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        engine.stop()
        var identifier = deviceID
        let status = AudioUnitSetProperty(audioUnit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &identifier,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            errorMessage = "Не удалось переключить устройство вывода"
        }
        try? engine.start()

        selectedOutputUID = uid
        if persist { UserDefaults.standard.set(uid, forKey: "outputDeviceUID") }
        updateOutputFormat()
        if wasPlaying { play() }
    }

    private func updateOutputFormat() {
        if let uid = selectedOutputUID,
           let format = AudioDevices.streamFormat(uid: uid),
           format.rate > 0 {
            outputFormatDescription = AudioDevices.describe(rate: format.rate,
                                                            bits: format.bits,
                                                            channels: format.channels)
        } else {
            let format = engine.outputNode.outputFormat(forBus: 0)
            outputFormatDescription = AudioDevices.describe(rate: format.sampleRate,
                                                            bits: 0,
                                                            channels: Int(format.channelCount))
        }
    }

    // MARK: Радио

    /// Запускает интернет-станцию через AVPlayer; локальная очередь останавливается.
    func playRadio(_ station: RadioStation) {
        guard let url = station.url, url.scheme != nil else {
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
        radioNowPlaying = nil
        radioArtist = nil
        radioTrack = nil
        radioRetryAttempts = 0
        radioRetryWork?.cancel()
        startRadioStream(url: url)

        if url.scheme == "http" || url.scheme == "https" {
            let reader = IcyMetadataReader()
            icyReader = reader
            reader.start(url: url) { [weak self] title in
                let parts = IcyMetadataReader.splitTitle(title)
                Task { @MainActor [weak self] in
                    self?.radioNowPlaying = title
                    self?.radioArtist = parts.artist
                    self?.radioTrack = parts.title
                }
            }
        }
    }

    private func startRadioStream(url: URL) {
        radioPlayer?.pause()
        radioItemObservation?.invalidate()
        radioTimeObservation?.invalidate()
        radioBuffering = true

        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.volume = Float(isMuted ? 0 : volume)
        radioPlayer = avPlayer

        radioItemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentStation != nil else { return }
                switch item.status {
                case .readyToPlay:
                    self.errorMessage = nil
                    self.radioRetryAttempts = 0
                    self.radioBuffering = false
                case .failed:
                    self.scheduleRadioReconnect(reason: item.error?.localizedDescription ?? "поток недоступен")
                default:
                    break
                }
            }
        }

        radioTimeObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentStation != nil else { return }
                self.radioBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        avPlayer.play()
        isPlaying = true
    }

    private func scheduleRadioReconnect(reason: String) {
        guard currentStation != nil else { return }
        radioPlayer?.pause()
        isPlaying = false
        radioBuffering = true
        radioRetryWork?.cancel()

        guard radioRetryAttempts < 3 else {
            errorMessage = "Радио недоступно: \(reason)"
            radioBuffering = false
            return
        }
        radioRetryAttempts += 1
        errorMessage = "Переподключаюсь к станции (\(radioRetryAttempts)/3)…"
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let url = self.currentStation?.url else { return }
                self.startRadioStream(url: url)
            }
        }
        radioRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func stopRadioPlayback() {
        radioRetryWork?.cancel()
        radioRetryWork = nil
        radioRetryAttempts = 0
        radioTimeObservation?.invalidate()
        radioTimeObservation = nil
        radioBuffering = false
        icyReader?.cancel()
        icyReader = nil
        radioItemObservation?.invalidate()
        radioItemObservation = nil
        radioPlayer?.pause()
        radioPlayer = nil
        currentStation = nil
        radioNowPlaying = nil
        radioArtist = nil
        radioTrack = nil
    }

    // MARK: Управление

    func play() {
        if let radioPlayer {
            radioPlayer.play()
            isPlaying = true
            return
        }
        guard file != nil else { return }
        if activeNode.isPlaying { return }
        if !engine.isRunning {
            try? engine.start()
        }
        scheduleFromCurrentFrame()
        activeNode.volume = 1
        activeNode.play()
        isPlaying = true
        applyFade()
    }

    func pause() {
        if let radioPlayer {
            radioPlayer.pause()
            isPlaying = false
            radioBuffering = false
            return
        }
        cancelCrossfade()
        guard activeNode.isPlaying else { return }
        seekFrame = currentFrame()
        activeNode.pause()
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
        cancelCrossfade()
        activeNode.stop()
        isPlaying = false
        seekFrame = startFrame
        position = 0
    }

    func seek(to seconds: TimeInterval) {
        guard currentStation == nil, file != nil, sampleRate > 0 else { return }
        let clamped = max(0, min(seconds, duration))
        let frame = min(endFrame, startFrame + AVAudioFramePosition((clamped * sampleRate).rounded()))
        cancelCrossfade()
        seekFrame = frame
        position = clamped
        if activeNode.isPlaying { activeNode.volume = 1 }

        if activeNode.isPlaying {
            let wasPlaying = isPlaying
            activeNode.stop()
            isPlaying = false
            if wasPlaying { play() }
        }
    }

    func next(manual: Bool = false) {
        cancelCrossfade()
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

    // MARK: Кроссфейд

    private struct CrossfadeState {
        let node: AVAudioPlayerNode
        let file: AVAudioFile
        let track: Track
        let index: Int
        let startFrame: AVAudioFramePosition
        let endFrame: AVAudioFramePosition
        let sampleRate: Double
        let duration: TimeInterval
        let fade: TimeInterval
        let startedAt: Date
        let incomingToken: Int
    }

    private var crossfadeState: CrossfadeState?
    private var crossfadeTimer: Timer?

    /// Следующий индекс очереди с учётом перемешивания и повтора.
    private func upcomingIndex() -> Int? {
        guard !queue.isEmpty, repeatMode != .one else { return nil }
        var next = queueIndex + 1
        if isShuffle {
            guard queue.count > 1 else { return nil }
            var candidate = queueIndex
            while candidate == queueIndex { candidate = Int.random(in: 0..<queue.count) }
            next = candidate
        } else if next >= queue.count {
            guard repeatMode == .all else { return nil }
            next = 0
        }
        return queue.indices.contains(next) ? next : nil
    }

    private func startCrossfadeIfNeeded() {
        guard crossfadeSeconds > 0,
              crossfadeState == nil,
              currentStation == nil,
              isPlaying,
              activeNode.isPlaying,
              file != nil,
              duration > 0,
              position > 0.5 else { return }

        let remaining = duration - position
        guard remaining > 0.3, remaining <= crossfadeSeconds,
              let index = upcomingIndex(),
              queue.indices.contains(index) else { return }
        let track = queue[index]
        guard let nextFile = try? AVAudioFile(forReading: track.url) else { return }

        let nextRate = nextFile.processingFormat.sampleRate
        guard nextRate > 0 else { return }
        let fileDuration = Double(nextFile.length) / nextRate
        let segmentStart = max(0, min(track.cueStart ?? 0, fileDuration))
        let segmentEnd = max(segmentStart, min(track.cueEnd ?? fileDuration, fileDuration))
        let startFrame = AVAudioFramePosition((segmentStart * nextRate).rounded())
        let endFrame = min(nextFile.length,
                           max(startFrame + 1, AVAudioFramePosition((segmentEnd * nextRate).rounded())))
        let segmentDuration = nextRate > 0 ? Double(endFrame - startFrame) / nextRate : track.duration
        let fade = min(crossfadeSeconds, remaining, max(0.3, segmentDuration - 0.2))
        guard fade > 0.2 else { return }

        let incoming = idleNode
        incoming.stop()
        incoming.volume = 0

        let incomingToken = generation + 1
        incoming.scheduleSegment(nextFile,
                                 startingFrame: startFrame,
                                 frameCount: AVAudioFrameCount(endFrame - startFrame),
                                 at: nil,
                                 completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == incomingToken else { return }
                self.handleTrackEnd()
            }
        }
        incoming.play()

        crossfadeState = CrossfadeState(node: incoming,
                                        file: nextFile,
                                        track: track,
                                        index: index,
                                        startFrame: startFrame,
                                        endFrame: endFrame,
                                        sampleRate: nextRate,
                                        duration: segmentDuration,
                                        fade: fade,
                                        startedAt: Date(),
                                        incomingToken: incomingToken)
        startCrossfadeTimer()
    }

    private func startCrossfadeTimer() {
        crossfadeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCrossfade() }
        }
        crossfadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateCrossfade() {
        guard let state = crossfadeState,
              let active = activeNode else { return }
        let elapsed = Date().timeIntervalSince(state.startedAt)
        let progress = min(1, max(0, elapsed / max(0.05, state.fade)))
        active.volume = Crossfade.outgoing(progress)
        state.node.volume = Crossfade.incoming(progress)
        if progress >= 1 { finishCrossfade() }
    }

    private func finishCrossfade() {
        guard let state = crossfadeState else { return }
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeState = nil

        let old = activeNode
        old?.stop()
        old?.volume = 0

        activeNode = state.node
        file = state.file
        sampleRate = state.sampleRate
        startFrame = state.startFrame
        endFrame = state.endFrame
        seekFrame = state.startFrame
        totalFrames = state.file.length
        duration = state.duration
        currentTrack = state.track
        queueIndex = state.index
        generation = state.incomingToken
        activeNode.volume = 1
        position = 0
        applyReplayGain()
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        if let state = crossfadeState {
            state.node.stop()
            state.node.volume = 0
        }
        crossfadeState = nil
        activeNode?.volume = 1
        generation += 1
    }

    // MARK: Планирование сегмента

    private func scheduleFromCurrentFrame() {
        guard let file else { return }
        let remaining = endFrame - seekFrame
        guard remaining > 0 else { return }

        generation += 1
        let token = generation

        activeNode.scheduleSegment(
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
        guard crossfadeState == nil else { return }
        guard isPlaying || position >= duration - 0.5 else { return }
        if repeatMode == .one {
            seekFrame = startFrame
            position = 0
            scheduleFromCurrentFrame()
            activeNode.play()
            isPlaying = true
        } else {
            next()
        }
    }

    /// Пересчитывает громкость по позиции: мягкий вход и выход без щелчков.
    private func applyFade() {
        guard file != nil, isPlaying, activeNode.isPlaying, crossfadeState == nil else { return }
        let fade = max(0, transitionFadeSeconds)
        activeNode.volume = TransitionFade.factor(position: position,
                                              duration: duration,
                                              fadeIn: min(0.4, fade),
                                              fadeOut: fade)
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard let nodeTime = activeNode.lastRenderTime,
              let playerTime = activeNode.playerTime(forNodeTime: nodeTime) else { return seekFrame }
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
                self.startCrossfadeIfNeeded()
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
