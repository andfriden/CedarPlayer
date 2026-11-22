import Foundation
import Accelerate
import AVFoundation

/// FFT spectrum analyzer: 1024-point transform, 48 logarithmic bands,
/// attack/decay smoothing and peak hold. Implemented in-house.
final class SpectrumAnalyzer {

    static let bandCount = 48

    private let fftSize: Int
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var sampleRate: Float = 48000
    private var binRanges: [(lower: Int, upper: Int)] = []

    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private let lock = NSLock()

    /// Called with ready values (0…1) for bars and peaks.
    var onUpdate: (([Float], [Float]) -> Void)?

    init(fftSize: Int = 1024) {
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.window = vDSP.window(ofType: Float.self,
                                  usingSequence: .hanningDenormalized,
                                  count: fftSize,
                                  isHalfWindow: false)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        rebuildBands()
    }

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    func configure(sampleRate: Double) {
        guard sampleRate > 0 else { return }
        lock.lock()
        self.sampleRate = Float(sampleRate)
        rebuildBandsLocked()
        lock.unlock()
    }

    private func rebuildBands() {
        lock.lock(); rebuildBandsLocked(); lock.unlock()
    }

    private func rebuildBandsLocked() {
        let minHz: Float = 30
        let maxHz: Float = 16000
        let binWidth = sampleRate / Float(fftSize)
        var ranges: [(Int, Int)] = []
        let ratio = pow(maxHz / minHz, 1 / Float(SpectrumAnalyzer.bandCount))
        var previousUpper = 1
        for index in 0..<SpectrumAnalyzer.bandCount {
            let low = minHz * pow(ratio, Float(index))
            let high = low * ratio
            var lower = max(1, Int(low / binWidth))
            var upper = max(lower + 1, Int(high / binWidth))
            lower = max(lower, previousUpper)
            upper = max(upper, lower + 1)
            upper = min(upper, fftSize / 2 - 1)
            lower = min(lower, upper - 1)
            previousUpper = upper
            ranges.append((lower, upper))
        }
        binRanges = ranges
    }

    /// Processes an audio buffer. Keep this method light.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let setup = fftSetup,
              let channels = buffer.floatChannelData,
              buffer.frameLength >= UInt32(fftSize) else { return }

        lock.lock()
        let ranges = binRanges
        let sampleRate = self.sampleRate
        lock.unlock()
        guard !ranges.isEmpty else { return }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var samples = [Float](repeating: 0, count: fftSize)

        // Mono mix of the first channels.
        for frame in 0..<min(frames, fftSize) {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            samples[frame] = sum / Float(channelCount)
        }

        vDSP.multiply(samples, window, result: &samples)

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBufferPointer { samplePtr in
                    samplePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                var scale = Float(2) / Float(fftSize)
                vDSP.multiply(magnitudes, [Float](repeating: scale, count: magnitudes.count), result: &magnitudes)
                scale = 0

                var newBands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
                for (index, range) in ranges.enumerated() {
                    var sum: Float = 0
                    var count = 0
                    for bin in range.lower..<range.upper where bin < magnitudes.count {
                        sum += magnitudes[bin] * magnitudes[bin]
                        count += 1
                    }
                    guard count > 0 else { continue }
                    let rms = sqrt(sum / Float(count))
                    let db = 20 * log10(max(rms, 1e-7))
                    let normalized = (db + 60) / 60
                    newBands[index] = pow(max(0, min(1, normalized)), 0.72)
                }

                // Time-based ballistics: ~5 ms attack, ~90 ms decay, peaks hold longer.
                let dt = Float(buffer.frameLength) / max(1, Float(buffer.format.sampleRate))
                let attack = 1 - exp(-dt / 0.005)
                let release = 1 - exp(-dt / 0.09)
                lock.lock()
                for index in 0..<SpectrumAnalyzer.bandCount {
                    let target = newBands[index]
                    let current = smoothed[index]
                    let coefficient = target > current ? attack : release
                    smoothed[index] = current + (target - current) * coefficient
                    peaks[index] = max(smoothed[index], peaks[index] - dt * 0.9)
                }
                let resultBands = smoothed
                let resultPeaks = peaks
                lock.unlock()

                _ = sampleRate
                let handler = onUpdate
                DispatchQueue.main.async {
                    handler?(resultBands, resultPeaks)
                }
            }
        }
    }

    func reset() {
        lock.lock()
        smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        peaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        lock.unlock()
    }
}
