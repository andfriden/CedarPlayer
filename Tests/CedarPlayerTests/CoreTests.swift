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
        XCTAssertEqual(Set(albums.map(\.title)), ["Alpha", "Beta", "Без альбома"])
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

    func testEmbedsArtworkIntoMP3() throws {
        let url = directory.appendingPathComponent("embed.mp3")
        var file = Data("ID3".utf8)
        file.append(contentsOf: [3, 0, 0])
        file.append(contentsOf: [0, 0, 0, 0])
        file.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
        file.append(Data(count: 96))
        try file.write(to: url)

        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        try TagWriter.embedArtwork(image, in: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.artwork, image)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.suffix(96)), Array(repeating: 0, count: 96))
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

final class TransitionFadeTests: XCTestCase {
    func testMiddleIsFullVolume() {
        XCTAssertEqual(TransitionFade.factor(position: 10, duration: 30, fadeIn: 0.4, fadeOut: 1), 1, accuracy: 0.0001)
    }

    func testFadeInAndOut() {
        XCTAssertEqual(TransitionFade.factor(position: 0.2, duration: 30, fadeIn: 0.4, fadeOut: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TransitionFade.factor(position: 29.5, duration: 30, fadeIn: 0.4, fadeOut: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TransitionFade.factor(position: 30, duration: 30, fadeIn: 0.4, fadeOut: 1), 0, accuracy: 0.0001)
    }

    func testDisabledFadeIsSilentNoOp() {
        XCTAssertEqual(TransitionFade.factor(position: 0, duration: 10, fadeIn: 0, fadeOut: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(TransitionFade.factor(position: 10, duration: 10, fadeIn: 0, fadeOut: 0), 1, accuracy: 0.0001)
    }

    func testShortTrackDoesNotExceedBounds() {
        let value = TransitionFade.factor(position: 0.1, duration: 0.5, fadeIn: 0.4, fadeOut: 1)
        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThanOrEqual(value, 1)
    }
}

final class SmartRuleTests: XCTestCase {
    private func track(rating: Int = 0, daysAgo: Double = 0, duration: TimeInterval = 180, art: Bool = true) -> Track {
        var track = Track(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).flac"))
        track.rating = rating
        track.addedAt = Date().addingTimeInterval(-daysAgo * 86400)
        track.duration = duration
        if art { track.artwork = Data([1]) }
        return track
    }

    func testRulesFilterTracks() {
        let fresh = track(rating: 5)
        let old = track(rating: 2, daysAgo: 10)
        let noArt = track(art: false)
        let long = track(duration: 601)

        XCTAssertEqual(SmartRule.favorites.filter([fresh, old]).map(\.id), [fresh.id])
        XCTAssertEqual(SmartRule.recent.filter([fresh, old]).map(\.id), [fresh.id])
        XCTAssertTrue(SmartRule.noArtwork.filter([fresh, noArt]).contains { $0.id == noArt.id })
        XCTAssertEqual(SmartRule.longTracks.filter([fresh, long]).map(\.id), [long.id])
    }

    func testRatingSurvivesCodableRoundTrip() throws {
        var original = Track(url: URL(fileURLWithPath: "/tmp/roundtrip.flac"))
        original.rating = 4
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded.rating, 4)
    }
}

final class IcyMetadataTests: XCTestCase {
    func testExtractsStreamTitle() {
        let metadata = Data("StreamTitle='M83 - Midnight City';".utf8)
        XCTAssertEqual(IcyMetadataReader.extractTitle(from: metadata), "M83 - Midnight City")
    }

    func testMissingOrEmptyTitle() {
        XCTAssertNil(IcyMetadataReader.extractTitle(from: Data("StreamUrl='x';".utf8)))
        XCTAssertNil(IcyMetadataReader.extractTitle(from: Data("StreamTitle='';".utf8)))
    }
}

final class IcySplitTests: XCTestCase {
    func testSplitsArtistAndTrack() {
        let parts = IcyMetadataReader.splitTitle("M83 - Midnight City")
        XCTAssertEqual(parts.artist, "M83")
        XCTAssertEqual(parts.title, "Midnight City")
    }

    func testKeepsHyphenatedArtistName() {
        let parts = IcyMetadataReader.splitTitle("Jay-Z - 99 Problems")
        XCTAssertEqual(parts.artist, "Jay-Z")
        XCTAssertEqual(parts.title, "99 Problems")
    }

    func testSplitsOnlyFirstSeparator() {
        let parts = IcyMetadataReader.splitTitle("A - B - C")
        XCTAssertEqual(parts.artist, "A")
        XCTAssertEqual(parts.title, "B - C")
    }

    func testNoSeparator() {
        let parts = IcyMetadataReader.splitTitle("Just a track")
        XCTAssertNil(parts.artist)
        XCTAssertEqual(parts.title, "Just a track")
    }

    func testEnDash() {
        let parts = IcyMetadataReader.splitTitle("Artist – Song")
        XCTAssertEqual(parts.artist, "Artist")
        XCTAssertEqual(parts.title, "Song")
    }
}

final class MiniRotationTests: XCTestCase {
    func testFullTurnMatchesVinylSpeed() {
        XCTAssertEqual(MiniRotation.degreesPerSecond, 200, accuracy: 0.001)
        // Полный оборот переходит в 0, а не в 360.
        XCTAssertEqual(MiniRotation.advance(0, by: 1.8), 0, accuracy: 0.001)
    }

    func testAdvanceWrapsAndIgnoresBadDeltas() {
        XCTAssertEqual(MiniRotation.advance(350, by: 0.1), 10, accuracy: 0.001)
        XCTAssertEqual(MiniRotation.advance(42, by: 0), 42, accuracy: 0.001)
        XCTAssertEqual(MiniRotation.advance(42, by: -1), 42, accuracy: 0.001)
    }
}
