import XCTest
import GhosttyVt

final class GhosttyLibraryTests: XCTestCase {
    func testTerminalAndKittyPixelsFromReleaseBinary() throws {
        var terminal: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &terminal, 80, 24), GHOSTTY_SUCCESS)
        let handle = try XCTUnwrap(terminal)
        defer { ghostty_terminal_free(handle) }

        let input = Array("hello\u{1B}_Ga=T,f=32,s=1,v=1,i=42,q=2;/wAA/w==\u{1B}\\".utf8)
        input.withUnsafeBufferPointer { bytes in
            ghostty_terminal_vt_write(handle, bytes.baseAddress, bytes.count)
        }
        var graphics: GhosttyKittyGraphics?
        XCTAssertEqual(ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics), GHOSTTY_SUCCESS)
        let image = try XCTUnwrap(ghostty_kitty_graphics_image(graphics, 42))
        var pixels = GhosttyString()
        XCTAssertEqual(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &pixels), GHOSTTY_SUCCESS)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels.ptr, count: pixels.len)), [255, 0, 0, 255])

        XCTAssertEqual(ghostty_terminal_resize(handle, 100, 30, 8, 16), GHOSTTY_SUCCESS)
        var columns: UInt16 = 0
        XCTAssertEqual(ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &columns), GHOSTTY_SUCCESS)
        XCTAssertEqual(columns, 100)
    }
}
