import XCTest
import UIKit
import SpecttyTerminal
@testable import SpecttyUI

final class HardwareKeyInterpreterTests: XCTestCase {
    func testAltLetterFallsBackToASCIIBaseCharacter() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "ƒ",
            charactersIgnoringModifiers: "f",
            modifiers: [.alternate]
        )

        XCTAssertEqual(value, "f")
    }

    func testAltShiftCommaPreservesShiftedSymbol() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "<",
            charactersIgnoringModifiers: ",",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, "<")
    }

    func testAltShiftDigitUsesShiftedASCIISymbol() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "¡",
            charactersIgnoringModifiers: "1",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, "!")
    }

    func testControlShiftSixPreservesCaretForControlMapping() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "^",
            charactersIgnoringModifiers: "6",
            modifiers: [.control, .shift]
        )

        XCTAssertEqual(value, "^")
    }

    func testControlLeftBracketFallsBackToIgnoringModifiersWhenRawIsControlCharacter() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "\u{1B}",
            charactersIgnoringModifiers: "[",
            modifiers: [.control]
        )

        XCTAssertEqual(value, "[")
    }

    func testCommandShiftLetterPreservesShiftedLetter() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "C",
            charactersIgnoringModifiers: "c",
            modifiers: [.command, .shift]
        )

        XCTAssertEqual(value, "C")
    }

    func testAltShiftPeriodPreservesGreaterThan() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: ">",
            charactersIgnoringModifiers: ".",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, ">")
    }

    func testAltShiftFivePreservesPercent() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "%",
            charactersIgnoringModifiers: "5",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, "%")
    }

    func testControlShiftTwoPreservesAtSign() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "@",
            charactersIgnoringModifiers: "2",
            modifiers: [.control, .shift]
        )

        XCTAssertEqual(value, "@")
    }
    func testPrintableLayoutCharactersArePreserved() {
        XCTAssertEqual(HardwareKeyInterpreter.terminalCharacters(rawCharacters: "é", charactersIgnoringModifiers: "é", modifiers: []), "é")
        XCTAssertEqual(HardwareKeyInterpreter.terminalCharacters(rawCharacters: "@", charactersIgnoringModifiers: "q", modifiers: .alternate), "@")
        XCTAssertEqual(HardwareKeyInterpreter.terminalCharacters(rawCharacters: "1", charactersIgnoringModifiers: "&", modifiers: .shift), "1")
    }
}

private final class ShiftDigitKey: UIKey {
    override var keyCode: UIKeyboardHIDUsage { .keyboard1 }
    override var modifierFlags: UIKeyModifierFlags { .shift }
    override var characters: String { "!" }
    override var charactersIgnoringModifiers: String { "1" }
}

private final class ShiftDigitPress: UIPress {
    override var key: UIKey? { ShiftDigitKey() }
}

extension HardwareKeyInterpreterTests {
    @MainActor func testKittyHardwareShiftDigitReachesEncoderWithModifiersAndRelease() throws {
        let emulator = GhosttyTerminalEmulator()
        emulator.feed(Data("\u{1b}[>11u".utf8))
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), emulator: emulator)
        var sent = Data()
        view.onKeyInput = { sent.append(emulator.encodeKey($0)) }
        let press = ShiftDigitPress()
        let route = try XCTUnwrap(view.imeTextField.routePresses)
        XCTAssertTrue(route([press], nil, true).isEmpty)
        XCTAssertTrue(route([press], nil, false).isEmpty)
        XCTAssertEqual(sent, Data("\u{1b}[49;2u\u{1b}[49;2:3u".utf8))
        emulator.feed(Data("\u{1b}[<u".utf8))
        XCTAssertFalse(emulator.state.modes.contains(.kittyKeyboard))
        XCTAssertEqual(route([press], nil, true).count, 1)
    }
}
