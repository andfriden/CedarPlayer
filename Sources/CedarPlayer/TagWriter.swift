import Foundation

/// Поля, которые плеер умеет записывать обратно в файл.
struct TagEdit {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int
}

enum TagWriteError: LocalizedError {
    case unsupportedFormat
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Этот формат не поддерживает запись тегов. Доступны FLAC и MP3 с ID3v2."
        case .corrupt(let reason):
            return "Файл повреждён: \(reason)"
        }
    }
}

/// Перезаписывает теги FLAC (Vorbis comments) и MP3 (ID3v2.4), не трогая аудиоданные.
enum TagWriter {

    static func write(_ edit: TagEdit, to url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw TagWriteError.corrupt("не удалось открыть файл")
        }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 12)
        if head.count >= 4, head.prefix(4) == Data("fLaC".utf8) {
            try rewriteFLAC(edit, url: url, handle: handle)
        } else if head.count >= 3, head.prefix(3) == Data("ID3".utf8) {
            try rewriteID3(edit, url: url, handle: handle, head: head)
        } else {
            throw TagWriteError.unsupportedFormat
        }
    }

    // MARK: - FLAC

    private static func rewriteFLAC(_ edit: TagEdit, url: URL, handle: FileHandle) throws {
        var blocks: [(type: UInt8, data: Data)] = []
        var audioOffset: UInt64 = 4

        while true {
            handle.seek(toFileOffset: audioOffset)
            let header = handle.readData(ofLength: 4)
            guard header.count == 4 else { throw TagWriteError.corrupt("обрыв метаданных") }
            let isLast = (header[0] & 0x80) != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let body = handle.readData(ofLength: length)
            guard body.count == length else { throw TagWriteError.corrupt("короткий блок метаданных") }
            audioOffset += UInt64(4 + length)

            switch type {
            case 1:
                break                                   // старый padding выбрасываем
            case 4:
                let comments = parseVorbisComment(body)
                blocks.append((4, buildVorbisComment(update(comments, with: edit))))
            default:
                blocks.append((type, body))
            }
            if isLast { break }
        }

        if !blocks.contains(where: { $0.type == 4 }) {
            let block = buildVorbisComment(update([], with: edit))
            let index = blocks.firstIndex(where: { $0.type == 0 }).map { $0 + 1 } ?? 0
            blocks.insert((4, block), at: min(index, blocks.count))
        }
        blocks.append((1, Data(count: 8192)))

        var output = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            output.append((isLast ? 0x80 : 0) | block.type)
            let length = block.data.count
            output.append(UInt8((length >> 16) & 0xFF))
            output.append(UInt8((length >> 8) & 0xFF))
            output.append(UInt8(length & 0xFF))
            output.append(block.data)
        }

        try replaceFile(at: url) { out in
            out.write(output)
            handle.seek(toFileOffset: audioOffset)
            try copyRemainder(from: handle, to: out)
        }
    }

    private static func parseVorbisComment(_ body: Data) -> [(String, String)] {
        var reader = ByteReader(data: body)
        let vendorLength = Int(reader.readUInt32LE())
        _ = reader.readBytes(vendorLength)
        let count = Int(reader.readUInt32LE())
        var entries: [(String, String)] = []
        var index = 0
        while index < count && reader.remaining >= 4 {
            index += 1
            let length = Int(reader.readUInt32LE())
            guard length > 0, length <= reader.remaining, let entry = reader.readString(length) else { break }
            guard let separator = entry.firstIndex(of: "=") else { continue }
            entries.append((entry[..<separator].uppercased(), String(entry[entry.index(after: separator)...])))
        }
        return entries
    }

    private static func update(_ entries: [(String, String)], with edit: TagEdit) -> [(String, String)] {
        let managed: Set<String> = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "ALBUM ARTIST", "TRACKNUMBER"]
        var result = entries.filter { !managed.contains($0.0) }
        let additions: [(String, String)] = [
            ("TITLE", edit.title),
            ("ARTIST", edit.artist),
            ("ALBUM", edit.album),
            ("ALBUMARTIST", edit.albumArtist),
            ("TRACKNUMBER", edit.trackNumber > 0 ? String(edit.trackNumber) : "")
        ]
        result.append(contentsOf: additions.filter { !$0.1.isEmpty })
        return result
    }

    private static func buildVorbisComment(_ entries: [(String, String)]) -> Data {
        var output = Data()
        let vendor = Data("Cedar Player".utf8)
        output.append(littleEndian(UInt32(vendor.count)))
        output.append(vendor)
        output.append(littleEndian(UInt32(entries.count)))
        for (key, value) in entries {
            let bytes = Data("\(key)=\(value)".utf8)
            output.append(littleEndian(UInt32(bytes.count)))
            output.append(bytes)
        }
        return output
    }

    // MARK: - ID3v2

    private static func rewriteID3(_ edit: TagEdit, url: URL, handle: FileHandle, head: Data) throws {
        guard head.count >= 10 else { throw TagWriteError.corrupt("короткий заголовок ID3") }
        let major = Int(head[3])
        let flags = head[5]
        let size = syncSafe(head.subdata(in: 6..<10))
        var audioStart = 10 + size
        if major == 4, flags & 0x10 != 0 { audioStart += 10 }

        handle.seek(toFileOffset: 10)
        let payload = handle.readData(ofLength: size)
        let artwork = findAPIC(in: payload, major: major)

        var frames = Data()
        func appendText(_ id: String, _ value: String) {
            guard !value.isEmpty else { return }
            var body = Data([0x03])                    // UTF-8
            body.append(value.data(using: .utf8) ?? Data())
            appendFrame(id, body: body, to: &frames)
        }
        appendText("TIT2", edit.title)
        appendText("TPE1", edit.artist)
        appendText("TALB", edit.album)
        appendText("TPE2", edit.albumArtist)
        if edit.trackNumber > 0 { appendText("TRCK", String(edit.trackNumber)) }
        if let artwork { appendFrame("APIC", body: artwork, to: &frames) }
        frames.append(Data(count: 2048))                // запас под будущие правки

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [4, 0, 0])
        tag.append(syncSafeBytes(frames.count))
        tag.append(frames)

        try replaceFile(at: url) { out in
            out.write(tag)
            handle.seek(toFileOffset: UInt64(audioStart))
            try copyRemainder(from: handle, to: out)
        }
    }

    private static func appendFrame(_ id: String, body: Data, to output: inout Data) {
        output.append(Data(id.utf8))
        output.append(syncSafeBytes(body.count))
        output.append(contentsOf: [0, 0])
        output.append(body)
    }

    /// Возвращает тело кадра APIC как есть, чтобы не терять обложку при сохранении.
    private static func findAPIC(in payload: Data, major: Int) -> Data? {
        guard major != 2 else { return nil }
        var offset = 0
        while offset + 10 <= payload.count {
            let idData = payload.subdata(in: offset..<offset + 4)
            guard let id = String(data: idData, encoding: .isoLatin1), id.first != "\0" else { break }
            let sizeField = payload.subdata(in: offset + 4..<offset + 8)
            let size = major >= 4 ? syncSafe(sizeField)
                                  : Int(sizeField[0]) << 24 | Int(sizeField[1]) << 16 | Int(sizeField[2]) << 8 | Int(sizeField[3])
            guard size > 0, offset + 10 + size <= payload.count else { break }
            if id == "APIC" {
                return payload.subdata(in: offset + 10..<offset + 10 + size)
            }
            offset += 10 + size
        }
        return nil
    }

    // MARK: - Общее

    /// Пишет новый файл во временный путь и атомарно подменяет исходный.
    private static func replaceFile(at url: URL, build: (FileHandle) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".cedar-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: temp) else {
            throw TagWriteError.corrupt("не удалось создать временный файл")
        }
        do {
            try build(output)
            try output.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp,
                                                       backupItemName: nil,
                                                       options: [])
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func copyRemainder(from input: FileHandle, to output: FileHandle) throws {
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            output.write(chunk)
        }
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF),
              UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF),
              UInt8((value >> 24) & 0xFF)])
    }

    private static func syncSafe(_ bytes: Data) -> Int {
        bytes.prefix(4).reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    private static func syncSafeBytes(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F),
              UInt8((value >> 14) & 0x7F),
              UInt8((value >> 7) & 0x7F),
              UInt8(value & 0x7F)])
    }
}
