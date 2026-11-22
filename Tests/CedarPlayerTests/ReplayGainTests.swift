import XCTest
import AVFoundation
@testable import CedarPlayer

final class ReplayGainMathTests: XCTestCase {
    func testParsesGainStrings() {
        XCTAssertEqual(ReplayGain.parseGain("-7.23 dB"), -7.23)
        XCTAssertEqual(ReplayGain.parseGain("+3.0 dB"), 3.0)
        XCTAssertEqual(ReplayGain.parseGain(" -1,5 dB "), -1.5)
        XCTAssertNil(ReplayGain.parseGain("громко"))
    }

    func testEffectiveGainIsClampedAndPeakLimited() {
        XCTAssertEqual(ReplayGain.effectiveDB(trackGainDB: -7.5, peak: nil), -7.5, accuracy: 0.001)
        XCTAssertEqual(ReplayGain.effectiveDB(trackGainDB: 20, peak: nil), ReplayGain.maxBoostDB, accuracy: 0.001)
        XCTAssertEqual(ReplayGain.effectiveDB(trackGainDB: -100, peak: nil), ReplayGain.minGainDB, accuracy: 0.001)
        XCTAssertEqual(ReplayGain.effectiveDB(trackGainDB: nil, peak: 0.9), 0, accuracy: 0.001)
        // A peak of 0.5 allows at most +6 dB; a peak of 0.9 at most +0.9 dB.
        XCTAssertEqual(ReplayGain.effectiveDB(trackGainDB: 6, peak: 0.9), 20 * log10(1 / 0.9), accuracy: 0.001)
    }

    func testFactor() {
        XCTAssertEqual(Double(ReplayGain.factor(trackGainDB: nil, peak: nil)), 1, accuracy: 0.0001)
        XCTAssertEqual(Double(ReplayGain.factor(trackGainDB: -6.02, peak: nil)), 0.5, accuracy: 0.005)
    }
}

final class ReplayGainTagTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadsFLACReplayGainComments() throws {
        let comments = ["REPLAYGAIN_TRACK_GAIN=-7.50 dB", "REPLAYGAIN_TRACK_PEAK=0.987"]
        var body = Data()
        let vendor = Data("test".utf8)
        body.append(le32(UInt32(vendor.count)))
        body.append(vendor)
        body.append(le32(UInt32(comments.count)))
        for comment in comments {
            let bytes = Data(comment.utf8)
            body.append(le32(UInt32(bytes.count)))
            body.append(bytes)
        }

        var file = Data("fLaC".utf8)
        file.append(contentsOf: [0x00, 0x00, 0x00, 0x22])
        file.append(Data(count: 34))
        file.append(0x84)
        file.append(contentsOf: [UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)])
        file.append(body)

        let url = directory.appendingPathComponent("rg.flac")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.replayGainDB, -7.5)
        XCTAssertEqual(tags.replayGainPeak, 0.987)
    }

    func testReadsID3ReplayGainTXXX() throws {
        var frames = Data()
        func txxx(_ description: String, _ value: String) {
            var payload = Data([0x00])
            payload.append(Data(description.utf8))
            payload.append(0)
            payload.append(Data(value.utf8))
            frames.append(Data("TXXX".utf8))
            frames.append(bigEndian(UInt32(payload.count)))
            frames.append(contentsOf: [0, 0])
            frames.append(payload)
        }
        txxx("REPLAYGAIN_TRACK_GAIN", "-3.25 dB")
        txxx("REPLAYGAIN_TRACK_PEAK", "0.8")

        var file = Data("ID3".utf8)
        file.append(contentsOf: [3, 0, 0])
        file.append(syncSafe(frames.count))
        file.append(frames)
        file.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
        file.append(Data(count: 32))

        let url = directory.appendingPathComponent("rg.mp3")
        try file.write(to: url)

        let tags = TagReader.read(url: url)
        XCTAssertEqual(tags.replayGainDB, -3.25)
        XCTAssertEqual(tags.replayGainPeak, 0.8)
    }

    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private func syncSafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }
}

final class ArtworkCacheTests: XCTestCase {
    func testDeduplicatesAndPrunes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkCache(directory: directory)

        let image = Data([1, 2, 3, 4, 5])
        let first = try XCTUnwrap(cache.store(image))
        let second = try XCTUnwrap(cache.store(image))
        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)

        let other = try XCTUnwrap(cache.store(Data([9, 9, 9])))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)

        cache.prune(keeping: [other])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(remaining, [other])
        XCTAssertNil(cache.data(for: first))
        XCTAssertEqual(cache.data(for: other), Data([9, 9, 9]))
    }
}

final class LibraryPlaylistTests: XCTestCase {
    @MainActor
    func testImportGoesIntoSelectedPlaylistAndAddIgnoresSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("CEDAR_LIBRARY_DIR", directory.path, 1)
        defer {
            unsetenv("CEDAR_LIBRARY_DIR")
            try? FileManager.default.removeItem(at: directory)
        }

        let wavURL = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
            buffer.frameLength = 4410
            try file.write(from: buffer)
        }

        let library = Library()
        let playlist = library.createPlaylist(named: "Избранное")
        let imported = await library.importFiles([wavURL], into: playlist.id)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(library.playlists.first { $0.id == playlist.id }?.trackIDs.count, 1)

        // Adding a selection must not depend on the search field.
        library.searchText = "ничего-не-найдётся"
        let second = library.createPlaylist(named: "Второй")
        library.add(Set(library.tracks.map(\.id)), to: second.id)
        XCTAssertEqual(library.playlists.first { $0.id == second.id }?.trackIDs.count, 1)

        // Removal can be undone in one action.
        library.searchText = ""
        let removedID = try XCTUnwrap(library.tracks.first?.id)
        library.remove([removedID])
        XCTAssertEqual(library.tracks.count, 0)
        XCTAssertTrue(library.canUndoRemove)
        library.undoRemove()
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertFalse(library.canUndoRemove)
    }
}
