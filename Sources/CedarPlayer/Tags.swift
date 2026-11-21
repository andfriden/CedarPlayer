import Foundation

/// Теги, которые удаётся прочитать из файла без AVFoundation.
struct AudioTags {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var artwork: Data?
    var replayGainDB: Double?
    var replayGainPeak: Double?
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    var duration: TimeInterval?
}

/// Читает теги FLAC (Vorbis comments + PICTURE), ID3v2 в MP3 и обложку из папки.
enum TagReader {

    static func read(url: URL) -> AudioTags {
        var tags = AudioTags()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return tags }
        defer { try? handle.close() }

        let head = handle.readData(ofLength: 12)
        if head.count >= 4, head.prefix(4) == Data("fLaC".utf8) {
            tags = readFLAC(handle: handle, head: head)
        } else if head.count >= 3, head.prefix(3) == Data("ID3".utf8) {
            tags = readID3(handle: handle, head: head)
        }

        if tags.artwork == nil {
            tags.artwork = folderArtwork(for: url)
        }
        return tags
    }

    // MARK: FLAC

    private static func readFLAC(handle: FileHandle, head: Data) -> AudioTags {
        var tags = AudioTags()
        var offset: UInt64 = 4

        while true {
            handle.seek(toFileOffset: offset)
            let blockHeader = handle.readData(ofLength: 4)
            guard blockHeader.count == 4 else { break }
            let isLast = (blockHeader[0] & 0x80) != 0
            let type = blockHeader[0] & 0x7F
            let length = Int(blockHeader[1]) << 16 | Int(blockHeader[2]) << 8 | Int(blockHeader[3])
            let body = handle.readData(ofLength: length)

            switch type {
            case 0:
                if body.count >= 18 {
                    var reader = ByteReader(data: body)
                    _ = reader.readUInt16()                       // min block
                    _ = reader.readUInt16()                       // max block
                    _ = reader.readBytes(6)                       // min/max frame
                    let packed = reader.readUInt64()              // sample rate 20 | channels 3 | bps 5 | samples 36
                    let sampleRate = Double((packed >> 44) & 0xFFFFF)
                    let channels = Int((packed >> 41) & 0x7) + 1
                    let bitDepth = Int((packed >> 36) & 0x1F) + 1
                    let totalSamples = packed & 0xFFFFFFFFF
                    tags.sampleRate = sampleRate
                    tags.channels = channels
                    tags.bitDepth = bitDepth
                    if sampleRate > 0, totalSamples > 0 {
                        tags.duration = Double(totalSamples) / sampleRate
                    }
                }
            case 4:
                applyVorbisComment(body, to: &tags)
            case 6:
                if let picture = parsePicture(body) { tags.artwork = picture }
            default:
                break
            }

            offset += 4 + UInt64(length)
            if isLast { break }
        }
        return tags
    }

    private static func applyVorbisComment(_ body: Data, to tags: inout AudioTags) {
        var reader = ByteReader(data: body)
        let vendorLength = Int(reader.readUInt32LE())
        _ = reader.readBytes(vendorLength)
        let count = Int(reader.readUInt32LE())
        var processed = 0
        while reader.remaining >= 4 && processed < max(count, 0) {
            processed += 1
            let length = Int(reader.readUInt32LE())
            guard length > 0, length <= reader.remaining else { break }
            guard let entry = reader.readString(length) else { break }
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<separator].uppercased()
            let value = String(entry[entry.index(after: separator)...])
            switch key {
            case "TITLE": tags.title = value
            case "ARTIST": tags.artist = value
            case "ALBUM": tags.album = value
            case "ALBUMARTIST", "ALBUM ARTIST": tags.albumArtist = value
            case "TRACKNUMBER": tags.trackNumber = Int(value)
            case "REPLAYGAIN_TRACK_GAIN": tags.replayGainDB = ReplayGain.parseGain(value)
            case "REPLAYGAIN_ALBUM_GAIN":
                if tags.replayGainDB == nil { tags.replayGainDB = ReplayGain.parseGain(value) }
            case "REPLAYGAIN_TRACK_PEAK": tags.replayGainPeak = ReplayGain.parsePeak(value)
            default: break
            }
        }
    }

    private static func parsePicture(_ body: Data) -> Data? {
        var reader = ByteReader(data: body)
        _ = reader.readUInt32()                     // picture type
        let mimeLength = Int(reader.readUInt32())
        _ = reader.readBytes(mimeLength)
        let descriptionLength = Int(reader.readUInt32())
        _ = reader.readBytes(descriptionLength)
        _ = reader.readUInt32()                     // width
        _ = reader.readUInt32()                     // height
        _ = reader.readUInt32()                     // depth
        _ = reader.readUInt32()                     // colors
        let dataLength = Int(reader.readUInt32())
        guard dataLength > 0, dataLength <= reader.remaining else { return nil }
        return reader.readBytes(dataLength)
    }

    // MARK: ID3v2

    private static func readID3(handle: FileHandle, head: Data) -> AudioTags {
        var tags = AudioTags()
        guard head.count >= 10 else { return tags }
        let major = Int(head[3])
        let tagSize = syncSafe(head[6..<10])
        handle.seek(toFileOffset: 10)
        var payload = handle.readData(ofLength: tagSize)
        if major == 2 { payload = convertID3v22(payload) }

        var offset = 0
        while offset + 10 <= payload.count {
            let idData = payload.subdata(in: offset..<offset+4)
            guard let id = String(data: idData, encoding: .isoLatin1), id.first != "\0" else { break }
            let sizeField = payload.subdata(in: offset+4..<offset+8)
            let size: Int
            if major >= 4 {
                size = syncSafe(sizeField)
            } else {
                size = Int(sizeField[0]) << 24 | Int(sizeField[1]) << 16 | Int(sizeField[2]) << 8 | Int(sizeField[3])
            }
            let headerLength = 10
            guard size > 0, offset + headerLength + size <= payload.count else { break }
            let frame = payload.subdata(in: offset+headerLength..<offset+headerLength+size)

            switch id {
            case "TIT2": tags.title = decodeTextFrame(frame)
            case "TPE1": tags.artist = decodeTextFrame(frame)
            case "TALB": tags.album = decodeTextFrame(frame)
            case "TPE2": tags.albumArtist = decodeTextFrame(frame)
            case "TRCK": tags.trackNumber = Int(decodeTextFrame(frame)?.components(separatedBy: "/").first ?? "")
            case "APIC": tags.artwork = decodeAPIC(frame)
            case "TXXX":
                if let (description, value) = decodeUserTextFrame(frame) {
                    let key = description.uppercased()
                    if key.contains("REPLAYGAIN_TRACK_GAIN") {
                        tags.replayGainDB = ReplayGain.parseGain(value)
                    } else if key.contains("REPLAYGAIN_ALBUM_GAIN"), tags.replayGainDB == nil {
                        tags.replayGainDB = ReplayGain.parseGain(value)
                    } else if key.contains("REPLAYGAIN_TRACK_PEAK") {
                        tags.replayGainPeak = ReplayGain.parsePeak(value)
                    }
                }
            default: break
            }
            offset += headerLength + size
        }
        return tags
    }

    private static func convertID3v22(_ payload: Data) -> Data {
        // v2.2 использует 3-символьные идентификаторы и 3-байтовый размер.
        var output = Data()
        var offset = 0
        while offset + 6 <= payload.count {
            let idData = payload.subdata(in: offset..<offset+3)
            guard let id = String(data: idData, encoding: .isoLatin1), id.first != "\0" else { break }
            let size = Int(payload[offset+3]) << 16 | Int(payload[offset+4]) << 8 | Int(payload[offset+5])
            guard size > 0, offset + 6 + size <= payload.count else { break }
            let frame = payload.subdata(in: offset+6..<offset+6+size)
            let mapped: String?
            switch id {
            case "TT2": mapped = "TIT2"
            case "TP1": mapped = "TPE1"
            case "TAL": mapped = "TALB"
            case "TP2": mapped = "TPE2"
            case "TRK": mapped = "TRCK"
            case "PIC": mapped = "APIC"
            default: mapped = nil
            }
            if let mapped, let idBytes = mapped.data(using: .isoLatin1) {
                var sizeBytes = Data()
                let value = frame.count
                sizeBytes.append(UInt8((value >> 24) & 0xFF))
                sizeBytes.append(UInt8((value >> 16) & 0xFF))
                sizeBytes.append(UInt8((value >> 8) & 0xFF))
                sizeBytes.append(UInt8(value & 0xFF))
                output.append(idBytes)
                output.append(sizeBytes)
                output.append(Data([0, 0]))
                output.append(frame)
            }
            offset += 6 + size
        }
        return output
    }

    private static func decodeTextFrame(_ frame: Data) -> String? {
        guard let encoding = frame.first else { return nil }
        var body = frame.dropFirst()
        if encoding == 1 || encoding == 2 {
            if body.starts(with: [0xFF, 0xFE]) || body.starts(with: [0xFE, 0xFF]) {
                body = body.dropFirst(2)
            }
            let data = Data(body)
            let stringEncoding: String.Encoding = encoding == 1 ? .utf16LittleEndian : .utf16BigEndian
            return String(data: data, encoding: stringEncoding)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        if encoding == 3 {
            return String(data: Data(body), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return String(data: Data(body), encoding: .isoLatin1)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// TXXX: описание и значение, разделённые нулём по правилам кодировки.
    private static func decodeUserTextFrame(_ frame: Data) -> (String, String)? {
        guard let encoding = frame.first else { return nil }
        let body = Data(frame.dropFirst())
        let separator: [UInt8] = (encoding == 1 || encoding == 2) ? [0, 0] : [0]
        guard let range = body.range(of: Data(separator)) else { return nil }
        let description = decodeString(Data(body[body.startIndex..<range.lowerBound]), encoding: encoding) ?? ""
        let value = decodeString(Data(body[range.upperBound...]), encoding: encoding) ?? ""
        return (description, value)
    }

    private static func decodeString(_ data: Data, encoding: UInt8) -> String? {
        var body = data
        if encoding == 1 || encoding == 2 {
            if body.starts(with: [0xFF, 0xFE]) || body.starts(with: [0xFE, 0xFF]) {
                body = body.dropFirst(2)
            }
            let stringEncoding: String.Encoding = encoding == 1 ? .utf16LittleEndian : .utf16BigEndian
            return String(data: body, encoding: stringEncoding)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        if encoding == 3 {
            return String(data: body, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return String(data: body, encoding: .isoLatin1)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static func decodeAPIC(_ frame: Data) -> Data? {
        guard frame.count > 4 else { return nil }
        let encoding = frame[0]
        var index = 1
        // MIME (latin1, null-terminated)
        while index < frame.count && frame[index] != 0 { index += 1 }
        index += 1
        guard index < frame.count else { return nil }
        index += 1 // picture type
        // Description: разделитель зависит от кодировки
        if encoding == 1 || encoding == 2 {
            while index + 1 < frame.count && !(frame[index] == 0 && frame[index+1] == 0) { index += 1 }
            index += 2
        } else {
            while index < frame.count && frame[index] != 0 { index += 1 }
            index += 1
        }
        guard index < frame.count else { return nil }
        return frame.subdata(in: index..<frame.count)
    }

    private static func syncSafe(_ bytes: Data) -> Int {
        var value = 0
        for byte in bytes.prefix(4) {
            value = (value << 7) | Int(byte & 0x7F)
        }
        return value
    }

    // MARK: Обложка из папки

    private static let coverNames = ["cover.jpg", "cover.jpeg", "cover.png",
                                     "folder.jpg", "folder.jpeg", "folder.png",
                                     "front.jpg", "front.jpeg", "front.png",
                                     "album.jpg", "album.png"]

    static func folderArtwork(for url: URL) -> Data? {
        let directory = url.deletingLastPathComponent()
        for name in coverNames {
            let candidate = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                return data
            }
        }
        return nil
    }
}

/// Простой читатель бинарных данных с порядком байтов big-endian по умолчанию.
struct ByteReader {
    let data: Data
    private(set) var offset: Int = 0

    init(data: Data) { self.data = data }

    var remaining: Int { max(0, data.count - offset) }

    mutating func readBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        guard offset + count <= data.count else { offset = data.count; return Data() }
        let slice = data.subdata(in: offset..<offset+count)
        offset += count
        return slice
    }

    mutating func readUInt16() -> UInt16 {
        let bytes = readBytes(2)
        guard bytes.count == 2 else { return 0 }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    mutating func readUInt32() -> UInt32 {
        let bytes = readBytes(4)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    mutating func readUInt32LE() -> UInt32 {
        let bytes = readBytes(4)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
    }

    mutating func readUInt64() -> UInt64 {
        let bytes = readBytes(8)
        guard bytes.count == 8 else { return 0 }
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        return value
    }

    mutating func readString(_ count: Int) -> String? {
        String(data: readBytes(count), encoding: .utf8)
    }
}
