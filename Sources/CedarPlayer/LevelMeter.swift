import Foundation
import AVFoundation

/// Измеритель уровня: RMS и пик по каналам, сглаживание и удержание пиков.
/// Нормировка — от −60 дБ до 0 дБ в 0…1.
final class LevelMeter {

    struct Reading {
        var rms: [Float]     // по каналам, 0…1
        var peaks: [Float]
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

        lock.lock()
        let targetL = normalize(squares[0])
        let targetR = normalize(squares[1])
        rmsL = smooth(current: rmsL, target: targetL, attack: 0.9, release: 0.4)
        rmsR = smooth(current: rmsR, target: targetR, attack: 0.9, release: 0.4)
        peakL = max(normalize(peaks[0]), peakL - 0.03)
        peakR = max(normalize(peaks[1]), peakR - 0.03)
        let reading = Reading(rms: [rmsL, rmsR], peaks: [peakL, peakR])
        lock.unlock()

        let handler = onUpdate
        DispatchQueue.main.async { handler?(reading) }
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
