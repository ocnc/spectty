import XCTest
@testable import Spectty

final class PortEntryTests: XCTestCase {
    @MainActor func testPortEntryAcceptsOnlyValidUnformattedNumbers() {
        for port in [1, 22, 2222, 65_535] {
            XCTAssertEqual(ConnectionEditorView.parsePort(String(port)), port)
        }
        for text in ["", "0", "65536", "-22", "+22", "2,222", "22x", " 22", "２２", String(repeating: "9", count: 30)] {
            XCTAssertNil(ConnectionEditorView.parsePort(text), text)
        }
    }
}
