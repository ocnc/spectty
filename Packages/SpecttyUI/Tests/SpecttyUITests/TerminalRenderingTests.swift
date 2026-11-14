import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

@MainActor
final class TerminalRenderingTests: XCTestCase {
    private func pixels(_ terminal: GhosttyTerminalEmulator) throws -> Data {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = TerminalMetalRenderer(device: device, scaleFactor: 2)
        let size = CGSize(width: 80, height: 60)
        let rect = CGRect(origin: .zero, size: size)
        let frame = terminal.graphicsFrame(scrollOffset: 0, cellSize: CGSize(width: renderer.cellSize.width * 2, height: renderer.cellSize.height * 2), now: 0)
        renderer.updateImages(frame, viewportSize: size, contentRect: rect)
        renderer.update(state: terminal.state.activeScreen, scrollback: terminal.state.scrollback, scrollOffset: 0, viewportSize: size, contentRect: rect)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 160, height: 120, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.render(to: pass))
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var bytes = Data(count: 160 * 120 * 4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 120), mipmapLevel: 0) }
        return bytes
    }

    func testStylesAndShapedCharactersChangeRenderedPixels() throws {
        func render(_ text: String) throws -> Data {
            let terminal = GhosttyTerminalEmulator(columns: 6, rows: 3)
            terminal.feed(Data(("\u{1b}[?25l" + text).utf8))
            return try pixels(terminal)
        }
        let blank = try render(" ")
        let normal = try render("M")
        XCTAssertNotEqual(normal, blank)
        XCTAssertNotEqual(try render("\u{1b}[1mM"), normal)
        XCTAssertNotEqual(try render("\u{1b}[3mM"), normal)
        let underline = try render("\u{1b}[4m ")
        let strike = try render("\u{1b}[9m ")
        XCTAssertNotEqual(underline, blank)
        XCTAssertNotEqual(strike, blank)
        XCTAssertNotEqual(underline, strike)
        XCTAssertEqual(try render("\u{1b}[8;4;9mM"), blank)
        XCTAssertNotEqual(try render("e\u{301}"), try render("e"))
        XCTAssertNotEqual(try render("👩‍💻"), blank)
    }

    func testNativeCursorStylesReachRendererAndResetToPreference() throws {
        let terminal = GhosttyTerminalEmulator(columns: 6, rows: 3)
        terminal.setDefaultCursorStyle(.bar)
        let bar = try pixels(terminal)
        terminal.feed(Data("\u{1b}[2 q".utf8))
        let block = try pixels(terminal)
        terminal.feed(Data("\u{1b}[4 q".utf8))
        let underline = try pixels(terminal)
        XCTAssertNotEqual(bar, block)
        XCTAssertNotEqual(block, underline)
        XCTAssertNotEqual(bar, underline)
        terminal.feed(Data("\u{1b}[0 q".utf8))
        XCTAssertEqual(try pixels(terminal), bar)
    }
}
