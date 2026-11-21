import XCTest
@testable import CedarPlayer

final class FolderWatcherTests: XCTestCase {
    func testNotifiesOnChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = FolderWatcher(debounce: 0.2)
        defer { watcher.stopAll() }

        let expectation = expectation(description: "изменение папки")
        watcher.onChange = { url in
            XCTAssertEqual(url.standardizedFileURL, directory.standardizedFileURL)
            expectation.fulfill()
        }
        watcher.watch([directory])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("new.flac"))
        wait(for: [expectation], timeout: 5)
    }
}
