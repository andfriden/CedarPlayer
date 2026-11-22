import XCTest
@testable import CedarPlayer

final class LibraryFilterTests: XCTestCase {
    private func track(_ name: String, genre: String = "", year: String = "", rate: Double = 44100, bits: Int = 16) -> Track {
        var track = Track(url: URL(fileURLWithPath: "/tmp/\(name).flac"))
        track.genre = genre
        track.year = year
        track.sampleRate = rate
        track.bitDepth = bits
        return track
    }

    func testFiltersByGenreYearFormatAndQuality() {
        let rock = track("a", genre: "Rock", year: "1999")
        let jazz = track("b", genre: "Jazz", year: "2001", rate: 96000, bits: 24)
        var filter = LibraryFilter()
        filter.genre = "Rock"
        XCTAssertEqual(filter.apply(to: [rock, jazz]).map(\.displayTitle), ["a"])

        filter = LibraryFilter()
        filter.year = "2001"
        XCTAssertEqual(filter.apply(to: [rock, jazz]).map(\.displayTitle), ["b"])

        filter = LibraryFilter()
        filter.format = "FLAC"
        XCTAssertEqual(filter.apply(to: [rock, jazz]).count, 2)

        filter = LibraryFilter()
        filter.quality = .hiRes
        XCTAssertEqual(filter.apply(to: [rock, jazz]).map(\.displayTitle), ["b"])
    }

    func testMissingAndArtworkFilters() {
        var missing = track("missing")
        missing.isMissing = true
        let present = track("present")
        var filter = LibraryFilter()
        filter.onlyMissing = true
        XCTAssertEqual(filter.apply(to: [missing, present]).map(\.displayTitle), ["missing"])

        filter = LibraryFilter()
        filter.onlyWithArtwork = true
        XCTAssertTrue(filter.apply(to: [missing, present]).isEmpty)
    }
}
