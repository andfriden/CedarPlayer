import XCTest
import AVFoundation
@testable import CedarPlayer

final class OggTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "ogg", subdirectory: "Fixtures"))
    }

    func testMetadata() throws {
        let tags = try XCTUnwrap(OggMetadata.read(url: fixture()))
        XCTAssertEqual(tags.title, "Test Tone")
        XCTAssertEqual(tags.artist, "Cedar Tests")
        XCTAssertEqual(tags.album, "Fixtures")
        XCTAssertEqual(tags.trackNumber, 3)
        XCTAssertEqual(tags.year, "2024")
        XCTAssertEqual(tags.genre, "Test")
        XCTAssertEqual(tags.sampleRate, 44_100)
        XCTAssertEqual(tags.channels, 1)
        XCTAssertEqual(tags.duration ?? 0, 1, accuracy: 0.02)
        XCTAssertEqual(tags.artwork?.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    func testTranscodeIsCachedAndReadable() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("CEDAR_LIBRARY_DIR", cache.path, 1)
        defer {
            unsetenv("CEDAR_LIBRARY_DIR")
            try? FileManager.default.removeItem(at: cache)
        }

        let track = Track(url: try fixture())
        let first = try AudioTranscoder.transcode(track)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let file = try AVAudioFile(forReading: first)
        XCTAssertEqual(file.length, 44_100, accuracy: 2)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(try AudioTranscoder.transcode(track), first)
    }

    func testMetadataReaderImportsOgg() async throws {
        let track = await MetadataReader.read(url: try fixture())
        XCTAssertEqual(track.title, "Test Tone")
        XCTAssertEqual(track.artist, "Cedar Tests")
        XCTAssertEqual(track.duration, 1, accuracy: 0.02)
    }
}
