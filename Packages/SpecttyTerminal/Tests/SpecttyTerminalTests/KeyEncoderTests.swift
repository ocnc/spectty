import XCTest
@testable import SpecttyTerminal

final class KeyEncoderTests: XCTestCase {
    func testAltPrintableCharacterUsesEscapePrefix() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: .alt,
            isKeyDown: true,
            characters: "a"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data("\u{1B}a".utf8))
    }

    func testAltControlPrintableCharacterUsesEscapePrefixedControlCode() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: [.alt, .control],
            isKeyDown: true,
            characters: "a"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data([0x1B, 0x01]))
    }

    func testAltPercentUsesEscapePrefix() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: .alt,
            isKeyDown: true,
            characters: "%"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data("\u{1B}%".utf8))
    }

    func testAltShiftLessThanUsesEscapePrefixedShiftedSymbol() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: .alt,
            isKeyDown: true,
            characters: "<"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data("\u{1B}<".utf8))
    }

    func testControlCaretUsesStandardControlCode() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: .control,
            isKeyDown: true,
            characters: "^"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data([0x1E]))
    }

    func testControlSlashUsesUnitSeparator() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: .control,
            isKeyDown: true,
            characters: "/"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data([0x1F]))
    }

    func testControlAtUsesNull() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: .control,
            isKeyDown: true,
            characters: "@"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data([0x00]))
    }

    func testControlDigitAliasesUseStandardTerminalMappings() {
        let encoder = KeyEncoder()

        XCTAssertEqual(
            encoder.encode(
                KeyEvent(keyCode: 0, modifiers: .control, isKeyDown: true, characters: "2"),
                modes: []
            ),
            Data([0x00])
        )
        XCTAssertEqual(
            encoder.encode(
                KeyEvent(keyCode: 0, modifiers: .control, isKeyDown: true, characters: "6"),
                modes: []
            ),
            Data([0x1E])
        )
        XCTAssertEqual(
            encoder.encode(
                KeyEvent(keyCode: 0, modifiers: .control, isKeyDown: true, characters: "7"),
                modes: []
            ),
            Data([0x1F])
        )
        XCTAssertEqual(
            encoder.encode(
                KeyEvent(keyCode: 0, modifiers: .control, isKeyDown: true, characters: "8"),
                modes: []
            ),
            Data([0x7F])
        )
    }

    func testAltBackspaceUsesEscapePrefixedDelete() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0x2A,
            modifiers: .alt,
            isKeyDown: true,
            characters: "\u{7F}"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data([0x1B, 0x7F]))
    }

    func testAltReturnUsesEscapePrefixedCarriageReturn() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0x28,
            modifiers: .alt,
            isKeyDown: true,
            characters: "\r"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data([0x1B, 0x0D]))
    }
    func testModifiedNavigationAndKeyUp() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(KeyEvent(keyCode: 0x52, modifiers: .control, isKeyDown: true, characters: ""), modes: []), Data("\u{1b}[1;5A".utf8))
        XCTAssertEqual(encoder.encode(KeyEvent(keyCode: 0x50, modifiers: .alt, isKeyDown: true, characters: ""), modes: [.applicationCursor]), Data("\u{1b}[1;3D".utf8))
        XCTAssertTrue(encoder.encode(KeyEvent(keyCode: 0, modifiers: [], isKeyDown: false, characters: "x"), modes: []).isEmpty)
    }
}
