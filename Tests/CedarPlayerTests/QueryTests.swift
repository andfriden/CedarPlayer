import XCTest
@testable import CedarPlayer

@MainActor
final class QueryTests: XCTestCase {
    private func track(_ title: String, album: String = "", artist: String = "Artist") -> Track {
        var track = Track(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).flac"))
        track.title = title
        track.album = album
        track.artist = artist
        return track
    }

    func testQueryCacheInvalidatesOnRatingChange() {
        let first = track("Alpha")
        let second = track("Beta")
        let library = Library(testTracks: [first, second])

        _ = library.query(filterID: "all", search: "", sortKey: .title, ascending: true)
        library.setRating(5, for: [first.id])
        let result = library.query(filterID: "all", search: "", sortKey: .title, ascending: true)

        XCTAssertEqual(result.tracks.first { $0.id == first.id }?.rating, 5)
    }

    func testSortsByRating() {
        var low = track("Low")
        var high = track("High")
        low.rating = 1
        high.rating = 5
        let library = Library(testTracks: [high, low])

        let ascending = library.query(filterID: "all", search: "",
                                      sortKey: .rating, ascending: true)
        let descending = library.query(filterID: "all", search: "",
                                       sortKey: .rating, ascending: false)

        XCTAssertEqual(ascending.tracks.map(\.title), ["Low", "High"])
        XCTAssertEqual(descending.tracks.map(\.title), ["High", "Low"])
    }

    func testPlaylistQueryKeepsOrderAndSkipsMissing() {
        let first = track("A")
        let second = track("B")
        let library = Library(testTracks: [first, second])
        var playlist = Playlist(name: "Mix")
        playlist.trackIDs = [second.id, UUID(), first.id]
        library.playlists = [playlist]

        let result = library.query(filterID: playlist.id.uuidString,
                                   search: "",
                                   sortKey: .added,
                                   ascending: true)

        XCTAssertEqual(Set(result.tracks.map(\.title)), ["A", "B"])
        XCTAssertEqual(Set(library.tracks(in: playlist).map(\.title)), ["A", "B"])
        XCTAssertEqual(library.tracks(in: playlist).count, 2)
    }

    func testSearchUsesPreparedIndex() {
        let library = Library(testTracks: [
            track("Midnight City", album: "Hurry Up", artist: "M83"),
            track("Outro", album: "Hurry Up", artist: "M83")
        ])

        let result = library.query(filterID: "all", search: "hurry", sortKey: .title, ascending: true)
        XCTAssertEqual(result.tracks.count, 2)
    }

    func testMissingFilesStayInLibraryAndCanBeRelinked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("exists.flac")
        let missing = directory.appendingPathComponent("missing.flac")
        try Data([0]).write(to: existing)

        var first = track("Present")
        first.url = existing
        var second = track("Gone")
        second.url = missing
        let library = Library(testTracks: [first, second])

        library.refreshAvailability()

        XCTAssertEqual(library.tracks.count, 2)
        XCTAssertFalse(try XCTUnwrap(library.track(with: first.id)).isMissing)
        XCTAssertTrue(try XCTUnwrap(library.track(with: second.id)).isMissing)
        XCTAssertEqual(library.missingCount, 1)

        let replacement = directory.appendingPathComponent("replacement.flac")
        try Data([0]).write(to: replacement)
        library.replaceFile(for: second.id, with: replacement)

        XCTAssertFalse(try XCTUnwrap(library.track(with: second.id)).isMissing)
        XCTAssertEqual(library.track(with: second.id)?.url.lastPathComponent, "replacement.flac")
    }

    func testQueueDropsMissingTracks() {
        var missing = track("Missing")
        missing.url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        missing.isMissing = true
        let engine = PlayerEngine()

        engine.setQueue([missing], startAt: 0, autoplay: false)

        XCTAssertTrue(engine.queue.isEmpty)
        XCTAssertEqual(engine.errorMessage, "Файлы не найдены")
    }

    func testMixedArtworkFlag() {
        var one = track("One", album: "Same")
        one.artwork = Data([1])
        one.artworkID = "cover-a"
        var two = track("Two", album: "Same")
        two.artwork = Data([2])
        two.artworkID = "cover-b"
        let library = Library(testTracks: [one, two])

        let mixed = library.query(filterID: "all", search: "", sortKey: .title, ascending: true)
        XCTAssertTrue(mixed.mixedArtwork)

        two.artworkID = "cover-a"
        library.tracks = [one, two]
        let same = library.query(filterID: "all", search: "", sortKey: .title, ascending: true)
        XCTAssertFalse(same.mixedArtwork)
    }
}
