import Foundation

/// Tags that can be read from a file without AVFoundation.
struct AudioTags {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var genre: String?
    var year: String?
    var composer: String?
    var artwork: Data?
    var replayGainDB: Double?
    var replayGainPeak: Double?
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    var duration: TimeInterval?
}

/// Reads FLAC (Vorbis comments + PICTURE), ID3v2/v1, APE, RIFF INFO
/// tags (WAV/AIFF) and folder artwork.
enum TagReader {

    static func read(url: URL) -> AudioTags {
        var tags = AudioTags()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return tags }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        handle.seek(toFileOffset: 0)
        let head = handle.readData(ofLength: 12)

        if head.count >= 4, head.prefix(4) == Data("fLaC".utf8) {
            tags = readFLAC(handle: handle, head: head)
        } else if head.count >= 4, head.prefix(4) == Data("RIFF".utf8) {
            tags = readRIFF(handle: handle, fileSize: fileSize, bigEndian: false)
        } else if head.count >= 4, head.prefix(4) == Data("FORM".utf8) {
            tags = readRIFF(handle: handle, fileSize: fileSize, bigEndian: true)
        } else {
            if head.count >= 3, head.prefix(3) == Data("ID3".utf8) {
                tags = readID3(handle: handle, head: head)
            }
            mergeID3v1(handle: handle, fileSize: fileSize, into: &tags)
            mergeAPE(handle: handle, fileSize: fileSize, into: &tags)
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
                    _ = reader.readUInt16()
                    _ = reader.readUInt16()
                    _ = reader.readBytes(6)
                    let packed = reader.readUInt64()
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
            case "TRACKNUMBER": tags.trackNumber = Int(value.components(separatedBy: "/").first ?? "")
            case "DISCNUMBER": tags.discNumber = Int(value.components(separatedBy: "/").first ?? "")
            case "GENRE": tags.genre = value
            case "DATE", "YEAR": tags.year = value
            case "COMPOSER": tags.composer = value
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
        _ = reader.readUInt32()
        let mimeLength = Int(reader.readUInt32())
        _ = reader.readBytes(mimeLength)
        let descriptionLength = Int(reader.readUInt32())
        _ = reader.readBytes(descriptionLength)
        _ = reader.readUInt32()
        _ = reader.readUInt32()
        _ = reader.readUInt32()
        _ = reader.readUInt32()
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
        let payload = handle.readData(ofLength: tagSize)
        parseID3v2(payload, major: major, into: &tags)
        return tags
    }

    private static func parseID3v2(_ rawPayload: Data, major: Int, into tags: inout AudioTags) {
        let payload = major == 2 ? convertID3v22(rawPayload) : rawPayload
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
            case "TPOS": tags.discNumber = Int(decodeTextFrame(frame)?.components(separatedBy: "/").first ?? "")
            case "TCON": tags.genre = decodeTextFrame(frame)
            case "TDRC", "TYER": tags.year = decodeTextFrame(frame)
            case "TCOM": tags.composer = decodeTextFrame(frame)
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
    }

    private static func convertID3v22(_ payload: Data) -> Data {
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
            case "TPA": mapped = "TPOS"
            case "TCO": mapped = "TCON"
            case "TYE": mapped = "TYER"
            case "TCM": mapped = "TCOM"
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

    // MARK: ID3v1

    private static func mergeID3v1(handle: FileHandle, fileSize: UInt64, into tags: inout AudioTags) {
        guard fileSize >= 128 else { return }
        handle.seek(toFileOffset: fileSize - 128)
        let block = handle.readData(ofLength: 128)
        guard block.count == 128, block.prefix(3) == Data("TAG".utf8) else { return }

        func field(_ range: Range<Int>) -> String {
            String(data: block.subdata(in: range), encoding: .isoLatin1)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                ?? ""
        }

        if tags.title?.isEmpty ?? true { tags.title = field(3..<33) }
        if tags.artist?.isEmpty ?? true { tags.artist = field(33..<63) }
        if tags.album?.isEmpty ?? true { tags.album = field(63..<93) }
        let year = field(93..<97)
        if (tags.year?.isEmpty ?? true), !year.isEmpty { tags.year = year }
        let genreIndex = Int(block[127])
        if tags.genre == nil, genreIndex < id3v1Genres.count {
            tags.genre = id3v1Genres[genreIndex]
        }
    }

    // MARK: APE

    private static func mergeAPE(handle: FileHandle, fileSize: UInt64, into tags: inout AudioTags) {
        guard fileSize >= 32 else { return }
        handle.seek(toFileOffset: fileSize - 32)
        let footer = handle.readData(ofLength: 32)
        guard footer.count == 32, footer.prefix(8) == Data("APETAGEX".utf8) else { return }

        let tagSize = Int(readUInt32LE(footer, 12))
        let itemCount = Int(readUInt32LE(footer, 16))
        guard tagSize >= 32, UInt64(tagSize) <= fileSize else { return }

        let itemsStart = fileSize - UInt64(tagSize)
        handle.seek(toFileOffset: itemsStart)
        let items = handle.readData(ofLength: tagSize - 32)

        var offset = 0
        for _ in 0..<itemCount {
            guard offset + 8 <= items.count else { break }
            let valueSize = Int(readUInt32LE(items, offset))
            let flags = readUInt32LE(items, offset + 4)
            offset += 8
            guard let keyEnd = items[offset...].firstIndex(of: 0) else { break }
            let key = String(data: items[offset..<keyEnd], encoding: .isoLatin1)?.lowercased() ?? ""
            offset = keyEnd + 1
            guard valueSize >= 0, offset + valueSize <= items.count else { break }
            let value = items.subdata(in: offset..<offset+valueSize)
            offset += valueSize

            if flags & 0x2 != 0 { continue }             // binary frame
            guard let text = String(data: value, encoding: .utf8) ??
                    String(data: value, encoding: .isoLatin1) else { continue }
            switch key {
            case "title": if tags.title?.isEmpty ?? true { tags.title = text }
            case "artist": if tags.artist?.isEmpty ?? true { tags.artist = text }
            case "album": if tags.album?.isEmpty ?? true { tags.album = text }
            case "album artist", "albumartist": if tags.albumArtist?.isEmpty ?? true { tags.albumArtist = text }
            case "track": if tags.trackNumber == nil { tags.trackNumber = Int(text.components(separatedBy: "/").first ?? "") }
            case "disc": if tags.discNumber == nil { tags.discNumber = Int(text) }
            case "genre": if tags.genre == nil { tags.genre = text }
            case "year", "date": if tags.year?.isEmpty ?? true { tags.year = text }
            case "composer": if tags.composer?.isEmpty ?? true { tags.composer = text }
            default:
                if key.hasPrefix("cover art"), tags.artwork == nil, let zero = value.firstIndex(of: 0) {
                    tags.artwork = value.subdata(in: value.index(after: zero)..<value.endIndex)
                }
            }
        }
    }

    // MARK: RIFF (WAV/AIFF)

    private static func readRIFF(handle: FileHandle, fileSize: UInt64, bigEndian: Bool) -> AudioTags {
        var tags = AudioTags()
        var offset: UInt64 = 12

        while offset + 8 <= fileSize {
            handle.seek(toFileOffset: offset)
            let header = handle.readData(ofLength: 8)
            guard header.count == 8 else { break }
            let id = String(data: header.prefix(4), encoding: .isoLatin1) ?? ""
            let size = bigEndian ? Int(readUInt32BE(header, 4)) : Int(readUInt32LE(header, 4))
            guard size >= 0 else { break }

            switch id {
            case "LIST":
                handle.seek(toFileOffset: offset + 8)
                let listHeader = handle.readData(ofLength: 4)
                if String(data: listHeader, encoding: .isoLatin1) == "INFO" {
                    let body = handle.readData(ofLength: max(0, size - 4))
                    applyINFO(body, bigEndian: bigEndian, to: &tags)
                }
            case "id3 ", "ID3 ":
                handle.seek(toFileOffset: offset + 8)
                let body = handle.readData(ofLength: size)
                if body.count > 10, body.prefix(3) == Data("ID3".utf8) {
                    let major = Int(body[3])
                    let tagSize = syncSafe(body[6..<10])
                    let start = 10
                    let end = min(body.count, start + tagSize)
                    if start <= end {
                        parseID3v2(body.subdata(in: start..<end), major: major, into: &tags)
                    }
                }
            case "NAME":
                if tags.title == nil {
                    handle.seek(toFileOffset: offset + 8)
                    tags.title = String(data: handle.readData(ofLength: size), encoding: .utf8)
                }
            case "AUTH":
                if tags.artist == nil {
                    handle.seek(toFileOffset: offset + 8)
                    tags.artist = String(data: handle.readData(ofLength: size), encoding: .utf8)
                }
            default:
                break
            }

            offset += 8 + UInt64(size) + UInt64(size % 2)
        }
        return tags
    }

    private static func applyINFO(_ body: Data, bigEndian: Bool, to tags: inout AudioTags) {
        var offset = 0
        while offset + 8 <= body.count {
            let id = String(data: body.subdata(in: offset..<offset+4), encoding: .isoLatin1) ?? ""
            let size = bigEndian ? Int(readUInt32BE(body, offset + 4)) : Int(readUInt32LE(body, offset + 4))
            offset += 8
            guard size >= 0, offset + size <= body.count else { break }
            let raw = body.subdata(in: offset..<offset+size)
            let text = String(data: raw, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            offset += size + (size % 2)

            switch id.uppercased() {
            case "INAM": if tags.title?.isEmpty ?? true { tags.title = text }
            case "IART": if tags.artist?.isEmpty ?? true { tags.artist = text }
            case "IPRD": if tags.album?.isEmpty ?? true { tags.album = text }
            case "ICRD": if tags.year?.isEmpty ?? true { tags.year = text }
            case "IGNR": if tags.genre == nil { tags.genre = text }
            case "ITRK": if tags.trackNumber == nil { tags.trackNumber = Int(text.components(separatedBy: "/").first ?? "") }
            case "IMUS": if tags.composer?.isEmpty ?? true { tags.composer = text }
            default: break
            }
        }
    }

    // MARK: Shared decoders

    private static func decodeTextFrame(_ frame: Data) -> String? {
        guard let encoding = frame.first else { return nil }
        return decodeString(Data(frame.dropFirst()), encoding: encoding)
    }

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
        while index < frame.count && frame[index] != 0 { index += 1 }
        index += 1
        guard index < frame.count else { return nil }
        index += 1
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
        bytes.prefix(4).reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | UInt32(data[offset+1]) << 8
            | UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16
            | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
    }

    private static let id3v1Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock",
        "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack",
        "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop",
        "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic",
        "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret",
        "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal",
        "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"
    ]

    // MARK: Folder artwork

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

/// Simple binary reader with big-endian byte order by default.
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
