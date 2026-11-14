import XCTest
@testable import SpecttyTerminal

final class GhosttyIntegrationTests: XCTestCase {
    func testNativeRepliesClipboardAndModes() {
        let terminal = GhosttyTerminalEmulator(columns: 8, rows: 3)
        var responses = Data()
        var clipboard = ""
        terminal.onResponse = { responses.append($0) }
        terminal.onSetClipboard = { clipboard = $0 }
        terminal.onGetClipboard = { "hello" }
        terminal.feed(Data("\u{1b}[2;3H\u{1b}[6n\u{1b}]52;c;aGk=\u{7}\u{1b}[?2004h\u{1b}]2;native title\u{7}".utf8))
        XCTAssertTrue(String(decoding: responses, as: UTF8.self).contains("\u{1b}[2;3R"))
        XCTAssertEqual(clipboard, "hi")
        XCTAssertEqual(terminal.state.activeScreen.title, "native title")
        XCTAssertTrue(terminal.state.modes.contains(.bracketedPaste))
        responses.removeAll()
        terminal.feed(Data("\u{1b}]52;c;?\u{7}".utf8))
        XCTAssertTrue(String(decoding: responses, as: UTF8.self).contains("aGVsbG8="))
        terminal.onGetClipboard = { nil }
        responses.removeAll()
        terminal.feed(Data("\u{1b}]52;c;?\u{7}".utf8))
        XCTAssertFalse(String(decoding: responses, as: UTF8.self).contains("aGVsbG8="))
    }

    func testGraphicsPlacementReplacementDeletionAndAlternateScreen() throws {
        let terminal = GhosttyTerminalEmulator(columns: 8, rows: 4)
        func frame() -> TerminalGraphicsFrame {
            terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 1)
        }
        _ = frame()
        terminal.feed(Data("\u{1b}_Ga=T,f=32,s=1,v=1,c=2,r=2,i=42,z=-1,q=2;/wAA/w==\u{1b}\\".utf8))
        let first = try XCTUnwrap(frame().placements.first)
        XCTAssertEqual(first.image.rgba, Data([255, 0, 0, 255]))
        XCTAssertEqual(first.destination.width, 16)
        XCTAssertEqual(first.destination.height, 32)
        XCTAssertEqual(first.layer, 1)
        XCTAssertEqual(frame().placements.first?.image.generation, first.image.generation)
        XCTAssertFalse(terminal.state.activeScreen.text().contains("/wAA"))
        terminal.feed(Data("\u{1b}[?1049h".utf8))
        XCTAssertTrue(frame().placements.isEmpty)
        terminal.feed(Data("\u{1b}[?1049l".utf8))
        XCTAssertEqual(frame().placements.count, 1)
        terminal.feed(Data("\u{1b}_Ga=T,f=32,s=1,v=1,c=2,r=2,i=42,q=2;AAD//w==\u{1b}\\".utf8))
        let replacement = try XCTUnwrap(frame().placements.first)
        XCTAssertNotEqual(replacement.image.generation, first.image.generation)
        XCTAssertEqual(replacement.image.rgba, Data([0, 0, 255, 255]))
        terminal.feed(Data("\u{1b}_Ga=d,d=I,i=42,q=2\u{1b}\\".utf8))
        XCTAssertTrue(frame().placements.isEmpty)
    }

    func testGraphicsFollowScrollbackAndFragmentedTransmission() throws {
        let terminal = GhosttyTerminalEmulator(columns: 8, rows: 2)
        let bytes = Data("\u{1b}_Ga=T,f=24,s=1,v=1,c=1,r=1,i=1,q=2;AP8A\u{1b}\\".utf8)
        for byte in bytes { terminal.feed(Data([byte])) }
        let first = terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0)
        XCTAssertEqual(first.placements.first?.image.rgba, Data([0, 255, 0, 255]))
        terminal.feed(Data("\r\n\r\n\r\n".utf8))
        XCTAssertTrue(terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0).placements.isEmpty)
        let history = terminal.graphicsFrame(scrollOffset: terminal.scrollbackCount, cellSize: CGSize(width: 8, height: 16), now: 0)
        XCTAssertEqual(history.placements.count, 1)
    }
    func testAnimationTicksReplacePixelsAndStopScheduling() throws {
        let terminal = GhosttyTerminalEmulator(columns: 8, rows: 4)
        terminal.feed(Data(("\u{1b}_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\u{1b}\\" +
            "\u{1b}_Ga=f,f=32,i=1,s=1,v=1,z=40;AAD//w==\u{1b}\\" +
            "\u{1b}_Ga=a,i=1,r=1,z=30\u{1b}\\\u{1b}_Ga=a,i=1,s=3\u{1b}\\").utf8))
        func frame(_ time: Double) -> TerminalGraphicsFrame {
            terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: time)
        }
        let red = frame(1)
        XCTAssertEqual(red.placements.first?.image.rgba, Data([255, 0, 0, 255]))
        XCTAssertEqual(try XCTUnwrap(red.nextFrameDelay), 0.03, accuracy: 0.001)
        let blue = frame(1.031)
        XCTAssertEqual(blue.placements.first?.image.rgba, Data([0, 0, 255, 255]))
        XCTAssertNotEqual(red.placements.first?.image.generation, blue.placements.first?.image.generation)
        terminal.feed(Data("\u{1b}_Ga=a,i=1,s=1\u{1b}\\".utf8))
        XCTAssertNil(frame(1.05).nextFrameDelay)
    }

    func testVirtualAndRelativePlacements() throws {
        let terminal = GhosttyTerminalEmulator(columns: 10, rows: 5)
        _ = terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 10, height: 10), now: 0)
        terminal.feed(Data(("\u{1b}_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,U=1,c=2,r=1,q=2;////////\u{1b}\\" +
            "\u{1b}[2;4H\u{1b}[38;5;1;58;5;1m\u{10EEEE}\u{10EEEE}\u{1b}[0m" +
            "\u{1b}_Ga=t,f=32,i=2,s=1,v=1,q=2;/wAA/w==\u{1b}\\" +
            "\u{1b}_Ga=p,i=2,p=2,P=1,Q=1,H=1,V=1,c=1,r=1,q=2\u{1b}\\").utf8))
        let frame = terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 10, height: 10), now: 0)
        XCTAssertGreaterThanOrEqual(frame.placements.count, 2)
        let relative = try XCTUnwrap(frame.placements.first { $0.image.rgba == Data([255, 0, 0, 255]) })
        XCTAssertEqual(relative.destination.minX, 40)
        XCTAssertEqual(relative.destination.minY, 20)
    }

    func testKittyKeyboardNegotiationUsesNativeEncoder() {
        let terminal = GhosttyTerminalEmulator()
        terminal.feed(Data("\u{1b}[>3u".utf8))
        let key = KeyEvent(keyCode: 0x04, modifiers: .control, isKeyDown: true, characters: "a")
        XCTAssertEqual(terminal.encodeKey(key), Data("\u{1b}[97;5u".utf8))
        let release = KeyEvent(keyCode: 0x04, modifiers: .control, isKeyDown: false, characters: "a")
        XCTAssertEqual(terminal.encodeKey(release), Data("\u{1b}[97;5:3u".utf8))
    }

    func testKittyShiftedKeysUseUnshiftedLayoutCharacter() {
        let terminal = GhosttyTerminalEmulator()
        XCTAssertFalse(terminal.state.modes.contains(.kittyKeyboard))
        terminal.feed(Data("\u{1b}[>11u".utf8))
        XCTAssertTrue(terminal.state.modes.contains(.kittyKeyboard))
        for (hid, text, base, code): (UInt32, String, String, Int) in [
            (0x1e, "!", "1", 49), (0x36, "<", ",", 44),
            (0x1e, "1", "&", 38), (0x04, "A", "a", 97)
        ] {
            let press = KeyEvent(keyCode: hid, modifiers: .shift, isKeyDown: true, characters: text, unshiftedCharacters: base)
            XCTAssertEqual(terminal.encodeKey(press), Data("\u{1b}[\(code);2u".utf8))
            var release = press
            release.isKeyDown = false
            XCTAssertEqual(terminal.encodeKey(release), Data("\u{1b}[\(code);2:3u".utf8))
        }
    }

    func testPNGAndZlibPayloadsDecodeToOwnedPixels() throws {
        for (format, payload) in [("f=100", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="), ("f=32,o=z,s=1,v=1", "eJz7z8DwHwAE/wH/")] {
            let terminal = GhosttyTerminalEmulator(columns: 4, rows: 4)
            terminal.feed(Data("\u{1b}_Ga=T,\(format),i=1,c=1,r=1;\(payload)\u{1b}\\".utf8))
            let frame = terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0)
            let image = try XCTUnwrap(frame.placements.first?.image)
            terminal.feed(Data("\u{1b}c".utf8))
            XCTAssertEqual(image.rgba, Data([255, 0, 0, 255]))
            XCTAssertTrue(terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0).placements.isEmpty)
        }
    }

    func testPNGOrientationAndStraightAlpha() throws {
        let terminal = GhosttyTerminalEmulator(columns: 4, rows: 4)
        terminal.feed(Data("\u{1b}_Ga=T,f=100,i=1,c=1,r=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAACCAYAAACZgbYnAAAAEklEQVR4nGP4z8DQwMDA8P8/AA7+A35TPsZnAAAAAElFTkSuQmCC\u{1b}\\".utf8))
        let frame = terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0)
        let image = try XCTUnwrap(frame.placements.first?.image)
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.rgba, Data([255, 0, 0, 128, 0, 0, 255, 255]))
    }

    func testInvalidImagesRecoverWithoutLosingFollowingText() {
        let terminal = GhosttyTerminalEmulator(columns: 40, rows: 4)
        for command in [
            "a=T,f=100,i=1;bm90IGEgcG5n",
            "a=T,f=100,i=2;iVBORw0KGgo=",
            "a=T,f=32,s=10001,v=1,i=3;/wAA/w==",
            "a=T,f=32,s=1,v=1,o=z,i=4;bm90IHpsaWI=",
            "a=T,f=32,s=1,v=1,i=5;%%%"
        ] {
            terminal.feed(Data("\u{1b}_G\(command)\u{1b}\\".utf8))
            XCTAssertTrue(terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0).placements.isEmpty)
        }
        terminal.feed(Data("still alive\u{1b}_Ga=T,f=32,s=1,v=1,i=6;/wAA/w==\u{1b}\\".utf8))
        XCTAssertTrue(terminal.state.activeScreen.text().contains("still alive"))
        XCTAssertEqual(terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0).placements.first?.image.rgba, Data([255, 0, 0, 255]))
    }

    func testBellFocusAndBoundedRenderHolds() {
        let terminal = GhosttyTerminalEmulator()
        let bell = expectation(description: "native bell")
        terminal.onBell = { bell.fulfill() }
        terminal.feed(Data([7]))
        wait(for: [bell], timeout: 1)
        var responses = Data()
        terminal.onResponse = { responses.append($0) }
        terminal.setFocused(true)
        XCTAssertTrue(responses.isEmpty)
        terminal.feed(Data("\u{1b}[?1004h".utf8))
        terminal.setFocused(false)
        terminal.setFocused(false)
        terminal.setFocused(true)
        XCTAssertEqual(responses, Data("\u{1b}[O\u{1b}[I".utf8))
        terminal.feed(Data("\u{1b}[?2026hpartial".utf8))
        let start = terminal.renderHoldStarted!
        XCTAssertEqual(terminal.renderDelay(now: start), 1)
        XCTAssertEqual(terminal.renderDelay(now: start + 2), 0)
        terminal.feed(Data("\u{1b}[?2026l".utf8))
        XCTAssertNil(terminal.renderHoldStarted)
        terminal.feed(Data("\u{1b}[?2026h".utf8))
        terminal.resize(columns: 90, rows: 30)
        XCTAssertNil(terminal.renderHoldStarted)
        terminal.feed(Data("\u{1b}[?2026h\u{1b}c".utf8))
        XCTAssertNil(terminal.renderHoldStarted)
    }

    func testApplicationCursorOverridesDefaultUntilReset() {
        let terminal = GhosttyTerminalEmulator()
        func style() -> CursorStyle {
            _ = terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: 8, height: 16), now: 0)
            return terminal.state.activeScreen.cursor.style
        }
        terminal.setDefaultCursorStyle(.bar)
        XCTAssertEqual(style(), .bar)
        terminal.feed(Data("\u{1b}[2 q".utf8))
        XCTAssertEqual(style(), .block)
        terminal.setDefaultCursorStyle(.underline)
        XCTAssertEqual(style(), .block)
        terminal.feed(Data("\u{1b}[0 q".utf8))
        XCTAssertEqual(style(), .underline)
        terminal.feed(Data("\u{1b}[6 q\u{1b}c".utf8))
        XCTAssertEqual(style(), .underline)
    }

}
