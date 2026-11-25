import XCTest
@testable import CedarPlayer

final class LRCParserTests: XCTestCase {
    func testParsesTimestampsAndOffset() {
        let source = """
        [ar:Artist]
        [00:01.50]First
        [00:03.00][01:05.25]Again
        [offset:+200]
        """
        let lines = LRCParser.parse(source)

        XCTAssertEqual(lines.map(\.text), ["First", "Again", "Again"])
        XCTAssertEqual(lines[0].time, 1.7, accuracy: 0.001)
        XCTAssertEqual(lines[1].time, 3.2, accuracy: 0.001)
        XCTAssertEqual(lines[2].time, 65.45, accuracy: 0.001)
        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
    }

    func testPlainTextHasNoTimedLines() {
        XCTAssertTrue(LRCParser.parse("Просто текст без времени").isEmpty)
    }
}
