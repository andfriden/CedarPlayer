import Foundation
import CoreAudio
import AudioToolbox

enum DSDPlaybackError: LocalizedError {
    case invalidFile
    case unsupportedLayout
    case tooLarge
    case deviceUnavailable
    case unsupportedFormat
    case outputFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile: return L10n.string("Некорректный DSF-файл")
        case .unsupportedLayout: return L10n.string("Поддерживается только стерео DSF")
        case .tooLarge: return L10n.string("DSD-файл слишком велик для загрузки в память")
        case .deviceUnavailable: return L10n.string("Устройство вывода недоступно")
        case .unsupportedFormat: return L10n.string("DAC не поддерживает DoP в нужном формате")
        case .outputFailed: return L10n.string("Не удалось запустить вывод DoP")
        }
    }
}

/// Minimal DSF parser and DoP (DSD over PCM) packer.
/// DoP: two DSD bytes per channel occupy the low 16 bits of a 24-bit PCM frame;
/// the top byte carries 0x05 / 0xFA, alternating every frame.
struct DoPTrack {
    let bytes: [UInt8]
    let frames: Int
    let carrierRate: Double
    let dsdRate: Double
    let duration: TimeInterval

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 92, data.prefix(4) == Data("DSD ".utf8) else {
            throw DSDPlaybackError.invalidFile
        }
        func u32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            return UInt32(data[offset]) | UInt32(data[offset+1]) << 8
                | UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24
        }
        func u64(_ offset: Int) -> UInt64 {
            guard offset + 8 <= data.count else { return 0 }
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(data[offset+index]) << UInt64(index * 8) }
            return value
        }

        var offset = 28
        var channels = 0
        var rate = 0
        var sampleCount: UInt64 = 0
        var blockSize = 0
        var dataStart = 0
        var dataBytes = 0

        while offset + 12 <= data.count {
            let identifier = String(data: data.subdata(in: offset..<offset+4), encoding: .isoLatin1) ?? ""
            let chunkSize = Int(u64(offset + 4))
            let body = offset + 12
            guard chunkSize >= 12, body + chunkSize - 12 <= data.count else { break }
            switch identifier {
            case "fmt ":
                guard chunkSize >= 52 else { throw DSDPlaybackError.invalidFile }
                channels = Int(u32(body + 12))
                rate = Int(u32(body + 16))
                sampleCount = u64(body + 24)
                blockSize = Int(u32(body + 32))
            case "data":
                dataStart = body
                dataBytes = chunkSize - 12
            default:
                break
            }
            offset = body + chunkSize - 12
        }

        guard channels == 2, rate > 0, sampleCount > 0, blockSize > 0, dataBytes > 0 else {
            throw channels != 2 && channels > 0 ? DSDPlaybackError.unsupportedLayout : DSDPlaybackError.invalidFile
        }
        let bytesPerChannel = Int((sampleCount + 7) / 8)
        guard bytesPerChannel > 0, dataStart + dataBytes <= data.count else { throw DSDPlaybackError.invalidFile }
        let frames = (bytesPerChannel + 1) / 2
        guard frames * 6 <= 1_500_000_000 else { throw DSDPlaybackError.tooLarge }

        var channelData = [[UInt8]](repeating: [], count: 2)
        channelData[0].reserveCapacity(bytesPerChannel)
        channelData[1].reserveCapacity(bytesPerChannel)
        let blocks = (bytesPerChannel + blockSize - 1) / blockSize
        for block in 0..<blocks {
            let base = dataStart + block * blockSize * 2
            for channel in 0..<2 {
                let wanted = min(blockSize, bytesPerChannel - channelData[channel].count)
                guard wanted > 0, base + channel * blockSize + wanted <= data.count else { break }
                let start = base + channel * blockSize
                for index in start..<(start + wanted) {
                    channelData[channel].append(Self.reverseBits(data[index]))
                }
            }
        }
        guard channelData[0].count >= bytesPerChannel, channelData[1].count >= bytesPerChannel else {
            throw DSDPlaybackError.invalidFile
        }

        var packed = [UInt8]()
        packed.reserveCapacity(frames * 6)
        for frame in 0..<frames {
            let marker: UInt8 = frame % 2 == 0 ? 0x05 : 0xFA
            for channel in 0..<2 {
                let first = frame * 2
                let second = first + 1
                let a = channelData[channel][first]
                let b = second < bytesPerChannel ? channelData[channel][second] : 0
                packed.append(marker)
                packed.append(a)
                packed.append(b)
            }
        }

        self.bytes = packed
        self.frames = frames
        self.dsdRate = Double(rate)
        self.carrierRate = Double(rate) / 16
        self.duration = Double(sampleCount) / Double(rate)
    }

    private static func reverseBits(_ value: UInt8) -> UInt8 {
        var byte = value
        byte = (byte & 0xF0) >> 4 | (byte & 0x0F) << 4
        byte = (byte & 0xCC) >> 2 | (byte & 0x33) << 2
        byte = (byte & 0xAA) >> 1 | (byte & 0x55) << 1
        return byte
    }
}

private final class DoPContext {
    let bytes: [UInt8]
    let frameCount: Int
    var frameIndex: Int = 0
    var playing = false
    var finished = false

    init(bytes: [UInt8], frameCount: Int) {
        self.bytes = bytes
        self.frameCount = frameCount
    }
}

/// Direct CoreAudio output for a pre-packed DoP stream.
@MainActor
final class DSDPlayer {
    private let track: DoPTrack
    private let device: AudioDeviceID
    private let context: DoPContext
    private var procID: AudioDeviceIOProcID?
    private var savedHog: pid_t = -1
    private var savedRate: Double = 0
    private var configured = false

    var carrierRate: Double { track.carrierRate }
    var duration: TimeInterval { track.duration }
    var position: TimeInterval {
        min(duration, Double(context.frameIndex) / max(1, track.carrierRate))
    }
    var finished: Bool { context.finished }

    init(url: URL, deviceUID: String?) throws {
        track = try DoPTrack(url: url)
        guard let uid = deviceUID,
              let id = AudioDevices.deviceID(forUID: uid) ?? AudioDevices.deviceID(forUID: AudioDevices.defaultOutputUID ?? "") else {
            throw DSDPlaybackError.deviceUnavailable
        }
        device = id
        context = DoPContext(bytes: track.bytes, frameCount: track.frames)
        try configureDevice()
    }

    func play() throws {
        if procID == nil {
            var proc: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcID(device, dsdIOProc, Unmanaged.passUnretained(context).toOpaque(), &proc)
            guard status == noErr, let proc else { throw DSDPlaybackError.outputFailed }
            procID = proc
        }
        if let procID {
            let status = AudioDeviceStart(device, procID)
            guard status == noErr else { throw DSDPlaybackError.outputFailed }
        }
        context.playing = true
    }

    func pause() {
        context.playing = false
    }

    func stop() {
        context.playing = false
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
        restoreDevice()
    }

    func seek(to seconds: TimeInterval) {
        let frame = Int(max(0, min(seconds, duration)) * track.carrierRate)
        context.frameIndex = min(context.frameCount, frame)
        context.finished = false
    }

    private func configureDevice() throws {
        var hog = pid_t(-1)
        var hogSize = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(device, &Self.hogAddress, 0, nil, &hogSize, &hog)
        savedHog = hog
        configured = true
        var own = getpid()
        guard AudioObjectSetPropertyData(device, &Self.hogAddress, 0, nil,
                                         UInt32(MemoryLayout<pid_t>.size), &own) == noErr else {
            restoreDevice()
            throw DSDPlaybackError.deviceUnavailable
        }

        var rate = track.carrierRate
        var rateSize = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device, &Self.rateAddress, 0, nil, &rateSize, &savedRate)
        let rateStatus = AudioObjectSetPropertyData(device, &Self.rateAddress, 0, nil, rateSize, &rate)
        guard rateStatus == noErr else {
            restoreDevice()
            throw DSDPlaybackError.unsupportedFormat
        }

        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr else {
            restoreDevice()
            throw DSDPlaybackError.unsupportedFormat
        }
        var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr,
              let stream = streams.first else {
            restoreDevice()
            throw DSDPlaybackError.unsupportedFormat
        }

        guard var format = Self.findFormat(stream: stream, rate: track.carrierRate) else {
            restoreDevice()
            throw DSDPlaybackError.unsupportedFormat
        }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectSetPropertyData(stream, &formatAddress, 0, nil,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format) == noErr else {
            restoreDevice()
            throw DSDPlaybackError.unsupportedFormat
        }
        formatAddress.mSelector = kAudioStreamPropertyVirtualFormat
        _ = AudioObjectSetPropertyData(stream, &formatAddress, 0, nil,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format)
        configured = true
    }

    private func restoreDevice() {
        guard configured else { return }
        var hog = savedHog
        AudioObjectSetPropertyData(device, &Self.hogAddress, 0, nil, UInt32(MemoryLayout<pid_t>.size), &hog)
        if savedRate > 0 {
            var rate = savedRate
            AudioObjectSetPropertyData(device, &Self.rateAddress, 0, nil, UInt32(MemoryLayout<Double>.size), &rate)
        }
        configured = false
    }

    private static var hogAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyHogMode,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static var rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func findFormat(stream: AudioStreamID, rate: Double) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr else { return nil }
        var ranges = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                    count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &ranges) == noErr else { return nil }
        for range in ranges {
            var format = range.mFormat
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mSampleRate == rate,
                  format.mChannelsPerFrame == 2,
                  format.mBitsPerChannel == 24,
                  format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                  format.mFormatFlags & kAudioFormatFlagIsFloat == 0 else { continue }
            format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            format.mBytesPerFrame = 6
            format.mBytesPerPacket = 6
            format.mFramesPerPacket = 1
            format.mChannelsPerFrame = 2
            return format
        }
        return nil
    }
}

private func dsdIOProc(_ device: AudioObjectID,
                       _ now: UnsafePointer<AudioTimeStamp>,
                       _ inputData: UnsafePointer<AudioBufferList>,
                       _ inputTime: UnsafePointer<AudioTimeStamp>,
                       _ outputData: UnsafeMutablePointer<AudioBufferList>,
                       _ outputTime: UnsafePointer<AudioTimeStamp>,
                       _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let context = Unmanaged<DoPContext>.fromOpaque(clientData).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    guard let first = buffers.first, let destination = first.mData else { return noErr }
    let frames = Int(first.mDataByteSize) / 6
    guard frames > 0 else { return noErr }

    let available = max(0, context.frameCount - context.frameIndex)
    let copyFrames = context.playing ? min(frames, available) : 0
    if copyFrames > 0 {
        context.bytes.withUnsafeBytes { source in
            memcpy(destination, source.baseAddress!.advanced(by: context.frameIndex * 6), copyFrames * 6)
        }
        context.frameIndex += copyFrames
        if context.frameIndex >= context.frameCount { context.finished = true }
    }
    if copyFrames < frames {
        memset(destination.advanced(by: copyFrames * 6), 0, (frames - copyFrames) * 6)
    }
    return noErr
}
