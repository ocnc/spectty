import XCTest
@testable import SpecttyTerminal

final class DisplayChangeTests: XCTestCase {
    func testFeedAndResizeNotifyDisplayChanges() {
        let emulator = GhosttyTerminalEmulator(columns: 8, rows: 4)
        let changed = expectation(description: "display changes")
        changed.expectedFulfillmentCount = 2
        emulator.onDisplayChange = { changed.fulfill() }
        emulator.feed(Data("hello".utf8))
        emulator.resize(columns: 10, rows: 4)
        wait(for: [changed], timeout: 1)
        emulator.onDisplayChange = nil
        emulator.feed(Data("!".utf8))
    }
}
