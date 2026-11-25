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
        // Latin and Cyrillic ordering depends on the locale, so check composition and contents.
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
                                    albumArtist: "Кто-то", trackNumber: 3,
                                    genre: "Rock", year: "2004", composer: "Автор"), to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.title, "Заголовок")
        XCTAssertEqual(tags.artist, "Кто-то")
        XCTAssertEqual(tags.album, "Альбом")
        XCTAssertEqual(tags.trackNumber, 3)
        XCTAssertEqual(tags.genre, "Rock")
        XCTAssertEqual(tags.year, "2004")
        XCTAssertEqual(tags.composer, "Автор")

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

        try TagWriter.write(TagEdit(title: "MP3", artist: "A", album: "B", albumArtist: "C", trackNumber: 5,
                                    genre: "Pop", year: "2010"), to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.title, "MP3")
        XCTAssertEqual(tags.trackNumber, 5)
        XCTAssertEqual(tags.genre, "Pop")
        XCTAssertEqual(tags.year, "2010")

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
        // A full turn wraps to 0, not 360.
        XCTAssertEqual(MiniRotation.advance(0, by: 1.8), 0, accuracy: 0.001)
    }

    func testAdvanceWrapsAndIgnoresBadDeltas() {
        XCTAssertEqual(MiniRotation.advance(350, by: 0.1), 10, accuracy: 0.001)
        XCTAssertEqual(MiniRotation.advance(42, by: 0), 42, accuracy: 0.001)
        XCTAssertEqual(MiniRotation.advance(42, by: -1), 42, accuracy: 0.001)
    }
}

final class CrossfadeRampTests: XCTestCase {
    func testRampEndpoints() {
        XCTAssertEqual(Crossfade.outgoing(0), 1, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.outgoing(1), 0, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.incoming(0), 0, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.incoming(1), 1, accuracy: 0.0001)
    }

    func testRampIsClamped() {
        XCTAssertEqual(Crossfade.outgoing(-1), 1, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.outgoing(2), 0, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.incoming(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.incoming(2), 1, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.outgoing(0.25) + Crossfade.incoming(0.25), 1, accuracy: 0.0001)
    }
}

final class RadioLogoTests: XCTestCase {
    func testCandidatesStartWithCustomLogo() {
        let station = RadioStation(name: "S", urlString: "https://example.com/stream",
                                   logoURLString: "https://cdn.example.com/logo.png")
        let urls = RadioLogoLoader.candidates(for: station).map(\.absoluteString)
        XCTAssertEqual(urls.first, "https://cdn.example.com/logo.png")
        XCTAssertTrue(urls.contains("https://example.com/favicon.ico"))
        XCTAssertTrue(urls.contains("https://example.com/apple-touch-icon.png"))
    }

    func testStationSurvivesCodableRoundTripWithLogo() throws {
        let station = RadioStation(name: "S", urlString: "https://example.com/s",
                                   logoURLString: "https://example.com/l.png", logoID: "abc")
        let decoded = try JSONDecoder().decode(RadioStation.self, from: JSONEncoder().encode(station))
        XCTAssertEqual(decoded.logoID, "abc")
        XCTAssertEqual(decoded.logoURLString, "https://example.com/l.png")
    }

    func testOldStationJSONWithoutLogoDecodes() throws {
        let json = Data(#"{"id":"\#(UUID().uuidString)","name":"Old","urlString":"https://example.com/s"}"#.utf8)
        let station = try JSONDecoder().decode(RadioStation.self, from: json)
        XCTAssertNil(station.logoID)
        XCTAssertNil(station.logoURLString)
    }
}

final class VUCalibrationTests: XCTestCase {
    func testZeroVUIsMinus12dBFS() {
        XCTAssertEqual(VUCalibration.vu(fromDBFS: -12), 0, accuracy: 0.001)
        XCTAssertEqual(VUCalibration.dBFS(fromLevel: 0.8), -12, accuracy: 0.001)
        XCTAssertEqual(VUCalibration.position(forVU: 0),
                       VUCalibration.position(forDBFS: -12), accuracy: 0.001)
    }

    func testPositionIsMonotonicAndClamped() {
        let positions = stride(from: -40.0, through: 20.0, by: 1).map { VUCalibration.position(forVU: $0) }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(VUCalibration.position(forVU: -100), 0, accuracy: 0.001)
        XCTAssertEqual(VUCalibration.position(forVU: 100), 1, accuracy: 0.001)
        XCTAssertEqual(VUCalibration.position(forLevel: 0), 0, accuracy: 0.001)
        XCTAssertEqual(VUCalibration.position(forLevel: 1), 1, accuracy: 0.001)
    }

    func testInverseRoundTrip() {
        for vu in [-20.0, -10, -5, -1, 0, 3] {
            let position = VUCalibration.position(forVU: vu)
            XCTAssertEqual(VUCalibration.vu(fromPosition: position), vu, accuracy: 0.001)
        }
    }
}

final class AudioDevicesTests: XCTestCase {
    func testFormatDescription() {
        let previous = UserDefaults.standard.string(forKey: "appLanguage")
        defer { UserDefaults.standard.set(previous, forKey: "appLanguage") }

        UserDefaults.standard.set("ru", forKey: "appLanguage")
        XCTAssertEqual(AudioDevices.describe(rate: 48000, bits: 24, channels: 2), "48 кГц · 24 бит · 2 кан.")
        XCTAssertEqual(AudioDevices.describe(rate: 44100, bits: 16, channels: 2), "44.1 кГц · 16 бит · 2 кан.")
        XCTAssertEqual(AudioDevices.describe(rate: 96000, bits: 0, channels: 6), "96 кГц · 6 кан.")

        UserDefaults.standard.set("en", forKey: "appLanguage")
        XCTAssertEqual(L10n.resolvedCode, "en")
        XCTAssertEqual(AudioDevices.describe(rate: 0, bits: 24, channels: 2), "—")
    }

    func testDeviceEnumerationDoesNotCrash() {
        _ = AudioDevices.outputs()
        _ = AudioDevices.defaultOutputUID
    }
}

final class AppearanceModeTests: XCTestCase {
    func testModesMapToSchemes() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.catppuccinLatte.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.catppuccinFrappe.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.catppuccinMacchiato.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.catppuccinMocha.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.allCases.map(\.title), [
            "Системное", "Тёмное", "Светлое", "Catppuccin Latte",
            "Catppuccin Frappé", "Catppuccin Macchiato", "Catppuccin Mocha"
        ])
    }
}
