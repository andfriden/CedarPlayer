import XCTest
import AVFoundation
@testable import CedarPlayer

final class OpusTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "opus", subdirectory: "Fixtures"))
    }

    func testMetadata() throws {
        let tags = try XCTUnwrap(OpusMetadata.read(url: fixture()))
        XCTAssertEqual(tags.title, "Opus Tone")
        XCTAssertEqual(tags.artist, "Cedar Tests")
        XCTAssertEqual(tags.sampleRate, 48_000)
        XCTAssertEqual(tags.channels, 1)
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
        XCTAssertEqual(file.length, 48_840, accuracy: 300)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(try AudioTranscoder.transcode(track), first)
    }

    func testMetadataReaderImportsOpus() async throws {
        let track = await MetadataReader.read(url: try fixture())
        XCTAssertEqual(track.title, "Opus Tone")
        XCTAssertEqual(track.artist, "Cedar Tests")
        XCTAssertEqual(track.duration, 1, accuracy: 0.02)
    }
}
