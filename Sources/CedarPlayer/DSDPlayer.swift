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

    private struct Parsed {
        let bytes: [UInt8]
        let frames: Int
        let dsdRate: Double
        let duration: TimeInterval
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parsed: Parsed
        if data.prefix(4) == Data("FRM8".utf8) {
            parsed = try Self.parseDFF(data)
        } else if data.prefix(4) == Data("DSD ".utf8) {
            parsed = try Self.parseDSF(data)
        } else {
            throw DSDPlaybackError.invalidFile
        }
        bytes = parsed.bytes
        frames = parsed.frames
        dsdRate = parsed.dsdRate
        carrierRate = parsed.dsdRate / 16
        duration = parsed.duration
    }

    /// Header-only probe for importing: duration, DSD rate and channel count.
    static func probe(url: URL) -> (duration: TimeInterval, rate: Double, channels: Int)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.prefix(4) == Data("FRM8".utf8) {
            guard let info = dffInfo(data) else { return nil }
            let channelBytes = info.dataBytes / max(1, info.channels)
            return (Double(channelBytes * 8) / Double(info.rate), Double(info.rate), info.channels)
        }
        if data.prefix(4) == Data("DSD ".utf8) {
            guard let info = dsfInfo(data) else { return nil }
            return (Double(info.sampleCount) / Double(info.rate), Double(info.rate), info.channels)
        }
        return nil
    }

    private static func parseDSF(_ data: Data) throws -> Parsed {
        guard let info = dsfInfo(data) else { throw DSDPlaybackError.invalidFile }
        guard info.channels == 2 else {
            throw info.channels > 0 ? DSDPlaybackError.unsupportedLayout : DSDPlaybackError.invalidFile
        }
        let bytesPerChannel = Int((info.sampleCount + 7) / 8)
        guard bytesPerChannel > 0,
              info.dataStart + info.dataBytes <= data.count else { throw DSDPlaybackError.invalidFile }
        let frames = (bytesPerChannel + 1) / 2
        guard frames * 6 <= 1_500_000_000 else { throw DSDPlaybackError.tooLarge }

        var channelData = [[UInt8]](repeating: [], count: 2)
        channelData[0].reserveCapacity(bytesPerChannel)
        channelData[1].reserveCapacity(bytesPerChannel)
        let blocks = (bytesPerChannel + info.blockSize - 1) / info.blockSize
        for block in 0..<blocks {
            let base = info.dataStart + block * info.blockSize * 2
            for channel in 0..<2 {
                let wanted = min(info.blockSize, bytesPerChannel - channelData[channel].count)
                guard wanted > 0, base + channel * info.blockSize + wanted <= data.count else { break }
                let start = base + channel * info.blockSize
                for index in start..<(start + wanted) {
                    channelData[channel].append(reverseBits(data[index]))
                }
            }
        }
        guard channelData[0].count >= bytesPerChannel,
              channelData[1].count >= bytesPerChannel else { throw DSDPlaybackError.invalidFile }
        return Parsed(bytes: pack(channelData, frames: frames),
                      frames: frames,
                      dsdRate: Double(info.rate),
                      duration: Double(info.sampleCount) / Double(info.rate))
    }

    private static func parseDFF(_ data: Data) throws -> Parsed {
        guard let info = dffInfo(data) else { throw DSDPlaybackError.invalidFile }
        guard info.channels == 2 else { throw DSDPlaybackError.unsupportedLayout }
        guard info.compression == "DSD " else { throw DSDPlaybackError.unsupportedLayout }
        let channelBytes = info.dataBytes / 2
        let frames = (channelBytes + 1) / 2
        guard frames * 6 <= 1_500_000_000 else { throw DSDPlaybackError.tooLarge }
        var left = [UInt8]()
        var right = [UInt8]()
        left.reserveCapacity(channelBytes)
        right.reserveCapacity(channelBytes)
        for index in 0..<channelBytes {
            let base = info.dataStart + index * 2
            guard base + 1 < data.count else { throw DSDPlaybackError.invalidFile }
            left.append(data[base])
            right.append(data[base + 1])
        }
        return Parsed(bytes: pack([left, right], frames: frames),
                      frames: frames,
                      dsdRate: Double(info.rate),
                      duration: Double(channelBytes * 8) / Double(info.rate))
    }

    private static func pack(_ channels: [[UInt8]], frames: Int) -> [UInt8] {
        var packed = [UInt8]()
        packed.reserveCapacity(frames * 6)
        for frame in 0..<frames {
            let marker: UInt8 = frame % 2 == 0 ? 0x05 : 0xFA
            for channel in 0..<2 {
                let first = frame * 2
                let second = first + 1
                let a = channels[channel][first]
                let b = second < channels[channel].count ? channels[channel][second] : 0
                packed.append(marker)
                packed.append(a)
                packed.append(b)
            }
        }
        return packed
    }

    private struct DSFInfo {
        let channels: Int
        let rate: UInt32
        let sampleCount: UInt64
        let blockSize: Int
        let dataStart: Int
        let dataBytes: Int
    }

    private static func dsfInfo(_ data: Data) -> DSFInfo? {
        guard data.count > 92, data.prefix(4) == Data("DSD ".utf8) else { return nil }
        var offset = 28
        var channels = 0
        var rate: UInt32 = 0
        var sampleCount: UInt64 = 0
        var blockSize = 0
        var dataStart = 0
        var dataBytes = 0
        while offset + 12 <= data.count {
            let identifier = String(data: data.subdata(in: offset..<offset+4), encoding: .isoLatin1) ?? ""
            let chunkSize = Int(u64le(data, offset + 4))
            let body = offset + 12
            guard chunkSize >= 12, body + chunkSize - 12 <= data.count else { break }
            switch identifier {
            case "fmt ":
                guard chunkSize >= 52 else { return nil }
                channels = Int(u32le(data, body + 12))
                rate = u32le(data, body + 16)
                sampleCount = u64le(data, body + 24)
                blockSize = Int(u32le(data, body + 32))
            case "data":
                dataStart = body
                dataBytes = chunkSize - 12
            default: break
            }
            offset = body + chunkSize - 12
        }
        guard channels > 0, rate > 0, sampleCount > 0, blockSize > 0, dataBytes > 0 else { return nil }
        return DSFInfo(channels: channels, rate: rate, sampleCount: sampleCount,
                       blockSize: blockSize, dataStart: dataStart, dataBytes: dataBytes)
    }

    private struct DFFInfo {
        let channels: Int
        let rate: UInt32
        let compression: String
        let dataStart: Int
        let dataBytes: Int
    }

    private static func dffInfo(_ data: Data) -> DFFInfo? {
        guard data.count >= 16, data.prefix(4) == Data("FRM8".utf8),
              data.subdata(in: 12..<16) == Data("DSD ".utf8) else { return nil }
        var offset = 16
        var channels = 0
        var rate: UInt32 = 0
        var compression = "DSD "
        var dataStart = 0
        var dataBytes = 0
        while offset + 12 <= data.count {
            let identifier = String(data: data.subdata(in: offset..<offset+4), encoding: .isoLatin1) ?? ""
            let size = Int(u64be(data, offset + 4))
            let body = offset + 12
            guard size >= 0, body + size <= data.count else { break }
            if identifier == "PROP", size >= 4 {
                var sub = body + 4
                while sub + 12 <= body + size {
                    let subID = String(data: data.subdata(in: sub..<sub+4), encoding: .isoLatin1) ?? ""
                    let subSize = Int(u64be(data, sub + 4))
                    let subBody = sub + 12
                    guard subSize >= 0, subBody + subSize <= body + size else { break }
                    switch subID {
                    case "FS  ": rate = subSize >= 4 ? u32be(data, subBody) : rate
                    case "CHNL": channels = subSize >= 2 ? Int(u16be(data, subBody)) : channels
                    case "CMPR":
                        if subSize >= 4,
                           let value = String(data: data.subdata(in: subBody..<subBody+4), encoding: .isoLatin1) {
                            compression = value
                        }
                    default: break
                    }
                    sub = subBody + subSize + (subSize % 2)
                }
            } else if identifier == "DSD " {
                dataStart = body
                dataBytes = size
            }
            offset = body + size + (size % 2)
        }
        guard channels > 0, rate > 0, dataBytes > 0 else { return nil }
        return DFFInfo(channels: channels, rate: rate, compression: compression,
                       dataStart: dataStart, dataBytes: dataBytes)
    }

    private static func u16be(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset+1])
    }
    private static func u32be(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16
            | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
    }
    private static func u64be(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(data[offset+index]) }
        return value
    }
    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | UInt32(data[offset+1]) << 8
            | UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24
    }
    private static func u64le(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(data[offset+index]) << UInt64(index * 8) }
        return value
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
