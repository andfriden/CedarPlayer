import XCTest
@testable import CedarPlayer

@MainActor
final class QueueTests: XCTestCase {
    private func track(_ title: String) -> Track {
        var track = Track(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).flac"))
        track.title = title
        return track
    }

    func testQueueOrderingAndRemoval() {
        let engine = PlayerEngine()
        engine.clearQueue()
        let first = track("First")
        let second = track("Second")
        let third = track("Third")

        engine.playNext(first)
        engine.addToQueue([second, third])
        XCTAssertEqual(engine.upNext.map(\.title), ["First", "Second", "Third"])

        engine.playNext(third)
        XCTAssertEqual(engine.upNext.map(\.title), ["Third", "First", "Second"])

        engine.removeFromQueue(first.id)
        XCTAssertEqual(engine.upNext.map(\.title), ["Third", "Second"])

        engine.clearQueue()
        XCTAssertTrue(engine.upNext.isEmpty)
    }
}
