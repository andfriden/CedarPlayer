import AVFoundation
import Accelerate

/// Built-in DSP equalizer: a peaking-biquad cascade per channel,
/// processing through vDSP_biquadm inside an AUAudioUnit.
final class BiquadEQAudioUnit: AUAudioUnit {

    static let bandCount = 10

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x43445245,          // 'CDRE'
        componentManufacturer: 0x43445231,     // 'CDR1'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    private var setup: OpaquePointer?
    private var setupChannels: Int = 0
    private var sampleRate: Double = 44100

    private var gains = [Double](repeating: 0, count: BiquadEQAudioUnit.bandCount)
    private var frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private var preampLinear: Float = 1
    private var isEnabled = false

    private let coefficientQueue = DispatchQueue(label: "cedar.biquad.coeffs")

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 8
        outputBus.maximumChannelCount = 8
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    // MARK: Settings

    func setBands(_ values: [Double], frequencies: [Double]) {
        coefficientQueue.sync {
            self.gains = values
            self.frequencies = frequencies
        }
        rebuildCoefficients()
    }

    func setPreamp(_ decibels: Double) {
        preampLinear = Float(pow(10, decibels / 20))
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    // MARK: Resources

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        sampleRate = outputBus.format.sampleRate
        rebuildSetup(channels: Int(outputBus.format.channelCount))
    }

    override func deallocateRenderResources() {
        if let setup { vDSP_biquadm_DestroySetup(setup) }
        setup = nil
        super.deallocateRenderResources()
    }

    private func rebuildSetup(channels: Int) {
        if let setup { vDSP_biquadm_DestroySetup(setup) }
        setupChannels = max(1, channels)
        let coefficients = makeCoefficients(sampleRate: sampleRate, channels: setupChannels)
        var mutable = coefficients
        setup = mutable.withUnsafeMutableBufferPointer { buffer in
            vDSP_biquadm_CreateSetup(buffer.baseAddress!, vDSP_Length(BiquadEQAudioUnit.bandCount),
                                     vDSP_Length(setupChannels))
        }
    }

    private func rebuildCoefficients() {
        guard let setup else { return }
        let coefficients = makeCoefficients(sampleRate: sampleRate, channels: setupChannels)
        var mutable = coefficients
        mutable.withUnsafeMutableBufferPointer { buffer in
            vDSP_biquadm_SetCoefficientsDouble(setup, buffer.baseAddress!,
                                               0, 0,
                                               vDSP_Length(BiquadEQAudioUnit.bandCount),
                                               vDSP_Length(setupChannels))
        }
    }

    /// Coefficients in order: section → channel → (b0, b1, b2, a1, a2), a0 = 1.
    private func makeCoefficients(sampleRate: Double, channels: Int) -> [Double] {
        let count = BiquadEQAudioUnit.bandCount * channels * 5
        var result = [Double](repeating: 0, count: count)
        for section in 0..<BiquadEQAudioUnit.bandCount {
            let gain = gains[section]
            let frequency = min(frequencies[section], sampleRate * 0.45)
            let (b0, b1, b2, a1, a2) = Self.peakingCoefficients(
                gainDB: gain, frequency: frequency, sampleRate: sampleRate, q: 1.0
            )
            for channel in 0..<channels {
                let base = (section * channels + channel) * 5
                result[base] = b0
                result[base + 1] = b1
                result[base + 2] = b2
                result[base + 3] = a1
                result[base + 4] = a2
            }
        }
        return result
    }

    private static func peakingCoefficients(gainDB: Double, frequency: Double,
                                            sampleRate: Double, q: Double)
        -> (Double, Double, Double, Double, Double) {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)

        let b0 = 1 + alpha * a
        let b1 = -2 * cosW0
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosW0
        let a2 = 1 - alpha / a

        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    // MARK: Rendering

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }

            var flags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
            if status != noErr { return status }

            guard state.isEnabled, let setup = state.setup else { return noErr }
            let channelCount = Int(outputData.pointee.mNumberBuffers)
            guard channelCount > 0 else { return noErr }

            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            var inputs = [UnsafePointer<Float>]()
            var outputs = [UnsafeMutablePointer<Float>]()
            inputs.reserveCapacity(channelCount)
            outputs.reserveCapacity(channelCount)

            for channel in 0..<channelCount {
                guard let data = buffers[channel].mData else { return noErr }
                let pointer = data.assumingMemoryBound(to: Float.self)
                inputs.append(UnsafePointer(pointer))
                outputs.append(pointer)
            }

            inputs.withUnsafeMutableBufferPointer { inBuffer in
                outputs.withUnsafeMutableBufferPointer { outBuffer in
                    vDSP_biquadm(setup, inBuffer.baseAddress!, 1,
                                 outBuffer.baseAddress!, 1, vDSP_Length(frameCount))
                }
            }

            if state.preampLinear != 1 {
                var gain = state.preampLinear
                for pointer in outputs {
                    vDSP_vsmul(pointer, 1, &gain, pointer, 1, vDSP_Length(frameCount))
                }
            }
            return noErr
        }
    }

    // MARK: Node creation

    static func registerOnce() {
        _ = registerLock
    }

    private static let registerLock: Void = {
        AUAudioUnit.registerSubclass(BiquadEQAudioUnit.self,
                                     as: componentDescription,
                                     name: "Cedar Biquad EQ",
                                     version: 1)
    }()

    static func makeNode() -> AVAudioUnit? {
        registerOnce()
        var result: AVAudioUnit?
        let semaphore = DispatchSemaphore(value: 0)
        AVAudioUnit.instantiate(with: componentDescription, options: [.loadInProcess]) { unit, _ in
            result = unit
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return result
    }
}
