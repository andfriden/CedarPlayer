import Foundation
import AVFoundation

/// Измеритель уровня: RMS и пик по каналам, сглаживание и удержание пиков.
/// Нормировка — от −60 дБ до 0 дБ в 0…1.
final class LevelMeter {

    struct Reading {
        var rms: [Float]     // сглаженные значения, 0…1
        var peaks: [Float]
        var raw: [Float]     // без сглаживания — для VU-баллистики
    }

    private var rmsL: Float = 0
    private var rmsR: Float = 0
    private var peakL: Float = 0
    private var peakR: Float = 0
    private let lock = NSLock()

    var onUpdate: ((Reading) -> Void)?

    func reset() {
        lock.lock()
        rmsL = 0; rmsR = 0; peakL = 0; peakR = 0
        lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var squares = [Float](repeating: 0, count: 2)
        var peaks = [Float](repeating: 0, count: 2)

        for channel in 0..<min(2, channelCount) {
            let data = channels[channel]
            var sum: Float = 0
            var maximum: Float = 0
            for frame in 0..<frames {
                let value = data[frame]
                sum += value * value
                maximum = max(maximum, abs(value))
            }
            squares[channel] = sum / Float(frames)
            peaks[channel] = maximum
        }
        if channelCount == 1 {
            squares[1] = squares[0]
            peaks[1] = peaks[0]
        }

        // Баллистика по времени, а не по числу буферов: быстрая атака, упругий спад.
        let dt = Float(Double(frames) / buffer.format.sampleRate)
        let attack = 1 - exp(-dt / 0.004)
        let release = 1 - exp(-dt / 0.09)
        let peakFall = dt * 1.1

        lock.lock()
        let targetL = display(normalize(squares[0]))
        let targetR = display(normalize(squares[1]))
        rmsL = smooth(current: rmsL, target: targetL, attack: attack, release: release)
        rmsR = smooth(current: rmsR, target: targetR, attack: attack, release: release)
        peakL = max(display(normalize(peaks[0])), peakL - peakFall)
        peakR = max(display(normalize(peaks[1])), peakR - peakFall)
        let reading = Reading(rms: [rmsL, rmsR], peaks: [peakL, peakR], raw: [targetL, targetR])
        lock.unlock()

        let handler = onUpdate
        DispatchQueue.main.async { handler?(reading) }
    }

    /// Небольшое расширение тихих участков, чтобы движения было видно.
    private func display(_ value: Float) -> Float {
        pow(max(0, min(1, value)), 0.85)
    }

    private func normalize(_ meanSquare: Float) -> Float {
        let rms = sqrt(max(meanSquare, 1e-12))
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 60) / 60))
    }

    private func smooth(current: Float, target: Float, attack: Float, release: Float) -> Float {
        current + (target - current) * (target > current ? attack : release)
    }
}
