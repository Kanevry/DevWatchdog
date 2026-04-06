import XCTest
@testable import DevWatchdog

final class PSParserTests: XCTestCase {

    // MARK: - parsePSLine

    func testParsesNormalLine() {
        let line = "  testuser  1234     1  12.3   4.5  51200 9:49AM /usr/local/bin/node server.js"
        let result = PSParser.parsePSLine(line)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.user, "testuser")
        XCTAssertEqual(result?.pid, 1234)
        XCTAssertEqual(result?.ppid, 1)
        XCTAssertEqual(result?.cpu, 12.3)
        XCTAssertEqual(result?.mem, 4.5)
        XCTAssertEqual(result?.rss, 51200)
        XCTAssertEqual(result?.command, "/usr/local/bin/node server.js")
    }

    func testCommandWithSpacesPreservesFullArgs() {
        let line = "  root  5678  100  80.0   2.0  10240 14:30 /usr/bin/node vitest --forks --reporter verbose"
        let result = PSParser.parsePSLine(line)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.command, "/usr/bin/node vitest --forks --reporter verbose")
    }

    func testEmptyLineReturnsNil() {
        XCTAssertNil(PSParser.parsePSLine(""))
    }

    func testInvalidLineReturnsNil() {
        XCTAssertNil(PSParser.parsePSLine("not enough columns"))
    }

    func testNonNumericPIDReturnsNil() {
        let line = "  testuser  abc     1  12.3   4.5  51200 9:49AM /usr/bin/node app.js"
        XCTAssertNil(PSParser.parsePSLine(line))
    }

    // MARK: - parseStartTime

    func testParseStartTimeHMMaa() {
        // "9:49AM" — h:mmaa format, should parse to today at 09:49
        let result = PSParser.parseStartTime("9:49AM")
        XCTAssertNotNil(result, "Should parse h:mmaa format")

        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: result!)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 49)
    }

    func testParseStartTimeHHmm() {
        let result = PSParser.parseStartTime("14:30")
        XCTAssertNotNil(result, "Should parse HH:mm format")

        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: result!)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
    }

    func testParseStartTimeMMMdd() {
        let result = PSParser.parseStartTime("Jan15")
        XCTAssertNotNil(result, "Should parse MMMdd format")

        let calendar = Calendar.current
        let components = calendar.dateComponents([.month, .day], from: result!)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
    }

    func testParseStartTimeYYYY() {
        let result = PSParser.parseStartTime("2025")
        XCTAssertNotNil(result, "Should parse YYYY format")

        let calendar = Calendar.current
        let year = calendar.component(.year, from: result!)
        XCTAssertEqual(year, 2025)
    }

    func testParseStartTimeInvalidReturnsNil() {
        XCTAssertNil(PSParser.parseStartTime("garbage"))
        XCTAssertNil(PSParser.parseStartTime(""))
        XCTAssertNil(PSParser.parseStartTime("abc123"))
    }
}
