import Foundation
import CoreAudio

struct AudioOutputDevice: Identifiable, Hashable {
    let id: String          // device UID
    let name: String
    let channels: Int
}

/// Enumerates and switches output devices through CoreAudio.
enum AudioDevices {
    static func outputs() -> [AudioOutputDevice] {
        deviceIDs().compactMap { id in
            let channels = outputChannels(id)
            guard channels > 0,
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: uid, name: name, channels: channels)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    static func uid(for deviceID: AudioDeviceID) -> String? {
        string(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static var defaultOutputUID: String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr else { return nil }
        return uid(for: deviceID)
    }

    /// Physical device stream format: rate, bit depth, channels.
    static func streamFormat(uid: String) -> (rate: Double, bits: Int, channels: Int)? {
        guard let id = deviceID(forUID: uid) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format) == noErr else { return nil }
        return (format.mSampleRate, Int(format.mBitsPerChannel), Int(format.mChannelsPerFrame))
    }

    /// "48 kHz · 24 bit · 2 ch." — extracted for tests.
    static func describe(rate: Double, bits: Int, channels: Int) -> String {
        guard rate > 0 else { return "—" }
        let khz = rate / 1000
        let rateText = khz == khz.rounded() ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        let depth = bits > 0 ? L10n.format("%ld бит · ", bits) : ""
        return L10n.format("%@ кГц · %@%ld кан.", rateText, depth, channels)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (value as String) : nil
    }
}
