import XCTest
@testable import CedarPlayer

final class PlaylistFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func track(_ name: String) -> Track {
        var track = Track(url: directory.appendingPathComponent(name))
        track.title = name
        track.artist = "Artist"
        track.duration = 125
        return track
    }

    func testM3URoundTrip() throws {
        let tracks = [track("one.flac"), track("two.flac")]
        let url = directory.appendingPathComponent("list.m3u")
        try PlaylistFile.m3u(tracks: tracks).write(to: url, atomically: true, encoding: .utf8)
        let parsed = PlaylistFile.parse(url)
        XCTAssertEqual(parsed.map(\.path), tracks.map { $0.url.standardizedFileURL.path })
    }

    func testPLSRoundTrip() throws {
        let tracks = [track("a.flac"), track("b.flac"), track("c.flac")]
        let url = directory.appendingPathComponent("list.pls")
        try PlaylistFile.pls(tracks: tracks).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(PlaylistFile.parse(url).count, 3)
    }

    func testRelativePathsAndComments() throws {
        let url = directory.appendingPathComponent("rel.m3u8")
        let text = """
        #EXTM3U
        #EXTINF:10,Artist - Song
        music/song.flac
        music/song.flac
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        let parsed = PlaylistFile.parse(url)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.path, directory.appendingPathComponent("music/song.flac").path)
    }
}
