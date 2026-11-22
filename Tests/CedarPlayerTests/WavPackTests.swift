import XCTest
import AVFoundation
@testable import CedarPlayer

final class WavPackTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "wv", subdirectory: "Fixtures"))
    }

    func testMetadata() throws {
        let tags = try XCTUnwrap(WavPackMetadata.read(url: fixture()))
        XCTAssertEqual(tags.title, "WavPack Tone")
        XCTAssertEqual(tags.artist, "Cedar Tests")
        XCTAssertEqual(tags.album, "Fixtures")
        XCTAssertEqual(tags.trackNumber, 3)
        XCTAssertEqual(tags.year, "2024")
        XCTAssertEqual(tags.genre, "Test")
        XCTAssertEqual(tags.sampleRate, 44_100)
        XCTAssertEqual(tags.channels, 2)
        XCTAssertEqual(tags.bitDepth, 16)
        XCTAssertEqual(tags.duration ?? 0, 1, accuracy: 0.02)
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
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(try AudioTranscoder.transcode(track), first)
    }

    func testMetadataReaderImportsWavPack() async throws {
        let track = await MetadataReader.read(url: try fixture())
        XCTAssertEqual(track.title, "WavPack Tone")
        XCTAssertEqual(track.artist, "Cedar Tests")
        XCTAssertEqual(track.duration, 1, accuracy: 0.02)
        XCTAssertNotNil(track.artwork)
    }
}

extension WavPackTests {
    func testFloatWavPackTranscode() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "float", withExtension: "wv", subdirectory: "Fixtures"))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("CEDAR_LIBRARY_DIR", cache.path, 1)
        defer {
            unsetenv("CEDAR_LIBRARY_DIR")
            try? FileManager.default.removeItem(at: cache)
        }
        let output = try AudioTranscoder.transcode(Track(url: url))
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, 192_000, accuracy: 2)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }
}
