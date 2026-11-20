import XCTest
@testable import CedarPlayer

final class AlbumGroupTests: XCTestCase {
    private func track(_ title: String, album: String, albumArtist: String = "", artist: String = "", number: Int = 0) -> Track {
        var track = Track(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).flac"))
        track.title = title
        track.album = album
        track.albumArtist = albumArtist
        track.artist = artist
        track.trackNumber = number
        return track
    }

    func testGroupsByAlbumAndAlbumArtist() {
        let tracks = [
            track("B", album: "Beta", albumArtist: "Artist", artist: "Artist", number: 2),
            track("A", album: "Beta", albumArtist: "Artist", artist: "Artist", number: 1),
            track("C", album: "Alpha", albumArtist: "Other", artist: "Other", number: 1),
            track("D", album: "", albumArtist: "", artist: "Solo", number: 1)
        ]
        let albums = AlbumGroup.group(tracks)
        // Порядок латиницы и кириллицы зависит от локали, поэтому проверяем состав и содержимое.
        XCTAssertEqual(Set(albums.map(\.title)), ["Alpha", "Beta", "Gamma", "Без альбома"])
        let beta = try? XCTUnwrap(albums.first { $0.title == "Beta" })
        XCTAssertEqual(beta?.tracks.map(\.title), ["A", "B"])
        let untitled = albums.first { $0.title == "Без альбома" }
        XCTAssertEqual(untitled?.artist, "Solo")
        XCTAssertEqual(beta?.tracks.count, 2)
    }

    func testSameAlbumDifferentArtistsStaySeparate() {
        let albums = AlbumGroup.group([
            track("X", album: "Shared", albumArtist: "One"),
            track("Y", album: "Shared", albumArtist: "Two")
        ])
        XCTAssertEqual(albums.count, 2)
    }

    func testArtworkTakenFromFirstTrackWithCover() {
        var first = track("X", album: "Covered")
        var second = track("Y", album: "Covered")
        second.artwork = Data([1, 2, 3])
        first.trackNumber = 1
        second.trackNumber = 2
        let album = AlbumGroup.group([first, second])[0]
        XCTAssertEqual(album.artwork, Data([1, 2, 3]))
    }
}

final class ByteReaderTests: XCTestCase {
    func testZeroLengthReadDoesNotConsume() {
        var reader = ByteReader(data: Data([0, 0, 0, 7]))
        XCTAssertEqual(reader.readBytes(0), Data())
        XCTAssertEqual(reader.readUInt32(), 7)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testShortReadConsumesRest() {
        var reader = ByteReader(data: Data([1, 2]))
        XCTAssertEqual(reader.readBytes(10), Data())
        XCTAssertEqual(reader.remaining, 0)
    }
}

final class TagWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFLAC() throws -> URL {
        var streamInfo = Data("fLaC".utf8)
        streamInfo.append(contentsOf: [0x00, 0x00, 0x00, 0x22])
        streamInfo.append(Data(count: 34))

        let vendor = Data("test".utf8)
        var comment = Data()
        comment.append(littleEndian(UInt32(vendor.count)))
        comment.append(vendor)
        comment.append(littleEndian(0))
        streamInfo.append(0x84)
        streamInfo.append(contentsOf: [0x00, 0x00, UInt8(comment.count)])
        streamInfo.append(comment)
        streamInfo.append(Data([0x11, 0x22, 0x33]))
        let url = directory.appendingPathComponent("test.flac")
        try streamInfo.write(to: url)
        return url
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    func testWritesFLACTagsAndKeepsAudio() throws {
        let url = try makeFLAC()
        try TagWriter.write(TagEdit(title: "Заголовок", artist: "Кто-то", album: "Альбом",
                                    albumArtist: "Кто-то", trackNumber: 3), to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.title, "Заголовок")
        XCTAssertEqual(tags.artist, "Кто-то")
        XCTAssertEqual(tags.album, "Альбом")
        XCTAssertEqual(tags.trackNumber, 3)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.suffix(3)), [0x11, 0x22, 0x33], "аудиоданные должны остаться в конце")
    }

    func testWritesMP3Tags() throws {
        let url = directory.appendingPathComponent("test.mp3")
        var file = Data("ID3".utf8)
        file.append(contentsOf: [3, 0, 0])
        file.append(contentsOf: [0, 0, 0, 0])
        file.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
        file.append(Data(count: 64))
        try file.write(to: url)

        try TagWriter.write(TagEdit(title: "MP3", artist: "A", album: "B", albumArtist: "C", trackNumber: 5), to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.title, "MP3")
        XCTAssertEqual(tags.trackNumber, 5)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data[3], 4, "должен быть ID3v2.4")
        XCTAssertEqual(Array(data.suffix(64)), Array(repeating: 0, count: 64))
    }

    func testRejectsUnsupportedFormat() throws {
        let url = directory.appendingPathComponent("note.wav")
        try Data("RIFF".utf8).write(to: url)
        XCTAssertThrowsError(try TagWriter.write(TagEdit(title: "x", artist: "", album: "",
                                                         albumArtist: "", trackNumber: 0), to: url))
    }
}

final class CueParserTests: XCTestCase {
    func testParsesTracksAndSegments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cue = directory.appendingPathComponent("album.cue")
        try """
        PERFORMER "Band"
        TITLE "Live"
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            PERFORMER "Guest"
            INDEX 01 03:30:00
        """.write(to: cue, atomically: true, encoding: .utf8)

        let sheet = CueParser.parse(url: cue)
        XCTAssertEqual(sheet?.tracks.count, 2)
        XCTAssertEqual(sheet?.title, "Live")
        XCTAssertEqual(sheet?.tracks[1].start, 210)
        XCTAssertEqual(sheet?.tracks[1].performer, "Guest")
        XCTAssertEqual(sheet?.fileURL.lastPathComponent, "album.flac")
    }
}

final class LibraryKeyTests: XCTestCase {
    func testCueSegmentsOfSameFileHaveDifferentKeys() {
        var first = Track(url: URL(fileURLWithPath: "/tmp/a.flac"))
        first.cueStart = 0
        var second = Track(url: URL(fileURLWithPath: "/tmp/a.flac"))
        second.cueStart = 12.5
        XCTAssertNotEqual(Library.key(for: first), Library.key(for: second))
        let firstCopy = Library.key(for: Track(url: URL(fileURLWithPath: "/tmp/a.flac")))
        let secondCopy = Library.key(for: Track(url: URL(fileURLWithPath: "/tmp/a.flac")))
        XCTAssertEqual(firstCopy, secondCopy)
        XCTAssertTrue(firstCopy.hasSuffix("#file"))
    }
}
