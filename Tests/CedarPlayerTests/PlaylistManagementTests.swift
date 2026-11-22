import XCTest
import AVFoundation
@testable import CedarPlayer

@MainActor
final class PlaylistManagementTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFolder(_ name: String, files: Int = 2) throws -> URL {
        let folder = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        for index in 0..<files {
            let url = folder.appendingPathComponent("track-\(index).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
            buffer.frameLength = 4410
            try file.write(from: buffer)
        }
        return folder
    }

    func testImportFolderAsPlaylistUsesFolderName() async throws {
        let folder = try makeFolder("Album Name")
        let library = Library(testTracks: [])

        let playlist = await library.importFolderAsPlaylist(folder)

        XCTAssertEqual(playlist?.name, "Album Name")
        XCTAssertEqual(playlist?.trackIDs.count, 2)
        XCTAssertEqual(library.tracks.count, 2)
    }

    func testImportSameFolderCreatesUniquePlaylistName() async throws {
        let folder = try makeFolder("Album")
        let library = Library(testTracks: [])

        _ = await library.importFolderAsPlaylist(folder)
        let second = await library.importFolderAsPlaylist(folder)

        XCTAssertEqual(second?.name, "Album 2")
        XCTAssertEqual(second?.trackIDs.count, 2)
        XCTAssertEqual(library.tracks.count, 2)
    }

    func testImportFolderRenamesEmptyPlaceholderOnly() async throws {
        let folder = try makeFolder("Live Set", files: 1)
        let library = Library(testTracks: [])
        let placeholder = library.createPlaylist(named: "Новый плейлист")

        let imported = await library.importFolder(folder, into: placeholder.id)

        XCTAssertTrue(imported)
        XCTAssertEqual(library.playlist(with: placeholder.id)?.name, "Live Set")

        let named = library.createPlaylist(named: "Моё")
        let other = try makeFolder("Other", files: 1)
        _ = await library.importFolder(other, into: named.id)
        XCTAssertEqual(library.playlist(with: named.id)?.name, "Моё")
    }

    func testRenameAndClearKeepPlaylistAndTracks() throws {
        let library = Library(testTracks: [])
        var track = Track(url: directory.appendingPathComponent("one.wav"))
        track.title = "One"
        library.tracks = [track]
        let playlist = library.createPlaylist(named: "Черновик")
        library.add([track.id], to: playlist.id)

        library.renamePlaylist(playlist.id, to: "   ")
        XCTAssertEqual(library.playlist(with: playlist.id)?.name, "Черновик")

        library.renamePlaylist(playlist.id, to: "Новое имя")
        XCTAssertEqual(library.playlist(with: playlist.id)?.name, "Новое имя")

        library.clearPlaylist(playlist.id)
        XCTAssertEqual(library.playlist(with: playlist.id)?.trackIDs.count, 0)
        XCTAssertEqual(library.tracks.count, 1)
    }
}
