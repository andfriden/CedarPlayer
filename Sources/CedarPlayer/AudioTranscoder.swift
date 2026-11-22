import Foundation
import AVFoundation
import CryptoKit
import CVorbis
import CWavPack
import COpus

enum AudioTranscoder {
    static let supported: Set<String> = ["ogg", "oga", "wv", "opus"]

    static func playbackURL(for track: Track) -> URL {
        guard supported.contains(track.url.pathExtension.lowercased()) else { return track.url }
        if let cached = cachedURL(for: track),
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        return (try? transcode(track)) ?? track.url
    }

    static func cachedURL(for track: Track) -> URL? {
        let values = try? track.url.resourceValues(forKeys: [.contentModificationDateKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("\(track.url.path)#\(stamp)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(key).m4a")
    }

    @discardableResult
    static func transcode(_ track: Track) throws -> URL {
        guard supported.contains(track.url.pathExtension.lowercased()) else { return track.url }
        if let cached = cachedURL(for: track), FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if track.url.pathExtension.lowercased() == "wv" {
            return try transcodeWavPack(track)
        }
        if track.url.pathExtension.lowercased() == "opus" {
            return try transcodeOpus(track)
        }

        var samples: UnsafeMutablePointer<Float>?
        var frames: Int32 = 0
        var channels: Int32 = 0
        var rate: Int32 = 0
        let result = track.url.path.withCString {
            cvorbis_decode($0, &samples, &frames, &channels, &rate)
        }
        guard result == 0, let samples, frames > 0, channels > 0, rate > 0 else {
            if let samples { cvorbis_free(samples) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { cvorbis_free(samples) }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(rate),
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let input = UnsafeBufferPointer(start: samples, count: Int(frames) * Int(channels))
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                destination[channel][frame] = input[frame * Int(channels) + channel]
            }
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let output = cacheDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: Double(rate),
            AVNumberOfChannelsKey: Int(channels)
        ])
        try file.write(from: buffer)
        guard let cached = cachedURL(for: track) else { throw CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: output, to: cached)
        return cached
    }


    private static func transcodeWavPack(_ track: Track) throws -> URL {
        guard let handle = track.url.path.withCString({ cwavpack_open($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { cwavpack_close(handle) }

        var channels: Int32 = 0
        var rate: Int32 = 0
        var bits: Int32 = 0
        var frames: Int64 = 0
        var isFloat: Int32 = 0
        var isDSD: Int32 = 0
        guard cwavpack_info(handle, &channels, &rate, &bits, &frames, &isFloat, &isDSD) == 0,
              channels > 0, rate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(rate),
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768),
              let destination = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let output = cacheDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            let file = try AVAudioFile(forWriting: output, settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: Double(rate),
                AVNumberOfChannelsKey: Int(channels),
                AVEncoderBitDepthHintKey: min(max(Int(bits), 16), 24)
            ])
            let capacity = 32_768
            var raw = [Float](repeating: 0, count: capacity * Int(channels))
            while true {
                let got = raw.withUnsafeMutableBufferPointer {
                    cwavpack_read(handle, $0.baseAddress, Int32(capacity))
                }
                if got < 0 { throw CocoaError(.fileReadCorruptFile) }
                if got == 0 { break }
                buffer.frameLength = AVAudioFrameCount(got)
                for channel in 0..<Int(channels) {
                    for frame in 0..<Int(got) {
                        destination[channel][frame] = raw[frame * Int(channels) + channel]
                    }
                }
                try file.write(from: buffer)
            }
            guard let cached = cachedURL(for: track) else { throw CocoaError(.fileWriteUnknown) }
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.moveItem(at: output, to: cached)
            return cached
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }


    private static func transcodeOpus(_ track: Track) throws -> URL {
        guard let handle = track.url.path.withCString({ copus_open($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { copus_close(handle) }

        var channels: Int32 = 0
        var rate: Int32 = 0
        var frames: Int64 = 0
        guard copus_info(handle, &channels, &rate, &frames) == 0,
              channels > 0, rate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(rate),
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768),
              let destination = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let output = cacheDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            let file = try AVAudioFile(forWriting: output, settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: Double(rate),
                AVNumberOfChannelsKey: Int(channels)
            ])
            let capacity = 32_768
            var raw = [Float](repeating: 0, count: capacity * Int(channels))
            while true {
                let got = raw.withUnsafeMutableBufferPointer {
                    copus_read(handle, $0.baseAddress, Int32(capacity))
                }
                if got < 0 { throw CocoaError(.fileReadCorruptFile) }
                if got == 0 { break }
                buffer.frameLength = AVAudioFrameCount(got)
                for channel in 0..<Int(channels) {
                    for frame in 0..<Int(got) {
                        destination[channel][frame] = raw[frame * Int(channels) + channel]
                    }
                }
                try file.write(from: buffer)
            }
            guard let cached = cachedURL(for: track) else { throw CocoaError(.fileWriteUnknown) }
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.moveItem(at: output, to: cached)
            return cached
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static var cacheDirectory: URL {
        let base: URL
        if let custom = ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"], !custom.isEmpty {
            base = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CedarPlayer", isDirectory: true)
        }
        return base.appendingPathComponent("Transcoded", isDirectory: true)
    }
}
