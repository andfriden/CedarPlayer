import XCTest
@testable import CedarPlayer

final class TagFormatsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func syncSafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
              UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }

    private func id3Frame(_ id: String, body: Data, major: Int) -> Data {
        var data = Data(id.utf8)
        if major == 4 {
            data.append(syncSafe(body.count))
        } else {
            data.append(Data([UInt8((body.count >> 24) & 0xFF), UInt8((body.count >> 16) & 0xFF),
                              UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)]))
        }
        data.append(Data([0, 0]))
        data.append(body)
        return data
    }

    private func id3Tag(major: Int, flags: UInt8, body: Data) -> Data {
        var data = Data("ID3".utf8)
        data.append(Data([UInt8(major), 0, flags]))
        data.append(syncSafe(body.count))
        data.append(body)
        return data
    }

    func testReadsAPICWithUTF16Description() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data("JFIF".utf8)
        var body = Data([1])
        body.append(Data("image/jpeg".utf8))
        body.append(0)
        body.append(3)
        body.append(Data([0xFF, 0xFE]))
        body.append("vkn.ext.net".data(using: .utf16LittleEndian)!)
        body.append(Data([0, 0]))
        body.append(image)

        let file = id3Tag(major: 3, flags: 0, body: id3Frame("APIC", body: body, major: 3))
        let url = directory.appendingPathComponent("utf16-apic.mp3")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.artwork, image)
    }

    func testReadsAPICAfterID3v24ExtendedHeader() throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("PNG".utf8)
        var body = Data([0])
        body.append(Data("image/png".utf8))
        body.append(0)
        body.append(3)
        body.append(0)
        body.append(image)

        let extended = Data([0, 0, 0, 6, 1, 0])
        let frames = extended + id3Frame("APIC", body: body, major: 4)
        let file = id3Tag(major: 4, flags: 0x40, body: frames)
        let url = directory.appendingPathComponent("extended-apic.mp3")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.artwork, image)
    }

    func testReadsID3v22PIC() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43]) + Data("JPEG".utf8)
        var body = Data([0])
        body.append(Data("JPG".utf8))
        body.append(3)
        body.append(Data("cover".utf8))
        body.append(0)
        body.append(image)

        var frame = Data("PIC".utf8)
        frame.append(Data([UInt8((body.count >> 16) & 0xFF),
                           UInt8((body.count >> 8) & 0xFF),
                           UInt8(body.count & 0xFF)]))
        frame.append(body)

        let file = id3Tag(major: 2, flags: 0, body: frame)
        let url = directory.appendingPathComponent("v22-pic.mp3")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.artwork, image)
    }

    func testReadsID3v1() throws {
        func pad(_ value: String, _ length: Int) -> Data {
            var data = Data(value.utf8.prefix(length))
            data.append(Data(count: max(0, length - data.count)))
            return data
        }
        var file = Data(count: 512)                       // "audio" without ID3v2
        file.append(Data("TAG".utf8))
        file.append(pad("Old Title", 30))
        file.append(pad("Old Artist", 30))
        file.append(pad("Old Album", 30))
        file.append(pad("1998", 4))
        file.append(pad("comment", 30))
        file.append(13)                                   // Pop

        let url = directory.appendingPathComponent("v1.mp3")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.title, "Old Title")
        XCTAssertEqual(tags.artist, "Old Artist")
        XCTAssertEqual(tags.album, "Old Album")
        XCTAssertEqual(tags.year, "1998")
        XCTAssertEqual(tags.genre, "Pop")
    }

    func testReadsRIFFInfo() throws {
        func chunk(_ id: String, _ value: String) -> Data {
            var data = Data(id.utf8)
            let bytes = Data(value.utf8) + Data([0])
            var size = UInt32(bytes.count)
            data.append(Data([UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 24) & 0xFF)]))
            data.append(bytes)
            if bytes.count % 2 == 1 { data.append(0) }
            size = 0
            return data
        }
        let infoBody = Data("INFO".utf8)
            + chunk("INAM", "Wav Title")
            + chunk("IART", "Wav Artist")
            + chunk("IPRD", "Wav Album")
            + chunk("ICRD", "2001")
            + chunk("IGNR", "Ambient")
            + chunk("ITRK", "4")

        var file = Data("RIFF".utf8)
        let riffSize = UInt32(4 + 8 + infoBody.count)
        file.append(Data([UInt8(riffSize & 0xFF), UInt8((riffSize >> 8) & 0xFF), UInt8((riffSize >> 16) & 0xFF), UInt8((riffSize >> 24) & 0xFF)]))
        file.append(Data("WAVE".utf8))
        file.append(Data("LIST".utf8))
        let listSize = UInt32(infoBody.count)
        file.append(Data([UInt8(listSize & 0xFF), UInt8((listSize >> 8) & 0xFF), UInt8((listSize >> 16) & 0xFF), UInt8((listSize >> 24) & 0xFF)]))
        file.append(infoBody)
        file.append(Data("data".utf8))
        file.append(Data(count: 4))

        let url = directory.appendingPathComponent("info.wav")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.title, "Wav Title")
        XCTAssertEqual(tags.artist, "Wav Artist")
        XCTAssertEqual(tags.album, "Wav Album")
        XCTAssertEqual(tags.year, "2001")
        XCTAssertEqual(tags.genre, "Ambient")
        XCTAssertEqual(tags.trackNumber, 4)
    }

    func testReadsAPETag() throws {
        func item(_ key: String, _ value: String) -> Data {
            let valueBytes = Data(value.utf8)
            var data = Data()
            var size = UInt32(valueBytes.count)
            data.append(Data([UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 24) & 0xFF)]))
            data.append(Data(count: 4))                    // flags: text frame
            data.append(Data(key.utf8))
            data.append(0)
            data.append(valueBytes)
            size = 0
            return data
        }
        let items = item("Title", "Ape Title") + item("Album", "Ape Album") + item("Genre", "Jazz")

        var file = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(count: 128)
        file.append(items)
        var footer = Data("APETAGEX".utf8)
        let total = UInt32(items.count + 32)
        var version: UInt32 = 2000
        footer.append(Data([UInt8(version & 0xFF), UInt8((version >> 8) & 0xFF), 0, 0]))
        footer.append(Data([UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF), UInt8((total >> 16) & 0xFF), UInt8((total >> 24) & 0xFF)]))
        var count = UInt32(3)
        footer.append(Data([UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF), UInt8((count >> 16) & 0xFF), UInt8((count >> 24) & 0xFF)]))
        footer.append(Data(count: 32 - footer.count))
        version = 0; count = 0
        file.append(footer)

        let url = directory.appendingPathComponent("ape.ape")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.title, "Ape Title")
        XCTAssertEqual(tags.album, "Ape Album")
        XCTAssertEqual(tags.genre, "Jazz")
    }
}
