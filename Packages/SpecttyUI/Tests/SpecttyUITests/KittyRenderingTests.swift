import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

@MainActor
final class KittyRenderingTests: XCTestCase {
    func testImageLayersAndClippingOnGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = TerminalMetalRenderer(device: device, scaleFactor: 1)
        let size = CGSize(width: 128, height: 128)
        let content = CGRect(x: 8, y: 8, width: 64, height: 64)
        for (z, imageWidth) in [(-1073741825, 1), (-1, 1), (1, 9_000)] {
            let emulator = GhosttyTerminalEmulator(columns: 4, rows: 4)
            _ = emulator.graphicsFrame(scrollOffset: 0, cellSize: renderer.cellSize, now: 0)
            let pixels = Data(Array(repeating: [UInt8](arrayLiteral: 255, 0, 0, 255), count: imageWidth).flatMap { $0 }).base64EncodedString()
            emulator.feed(Data("\u{1b}[?25l".utf8))
            let encoded = Array(pixels.utf8)
            for offset in stride(from: 0, to: encoded.count, by: 4096) {
                let end = min(offset + 4096, encoded.count)
                let more = end < encoded.count ? 1 : 0
                let options = offset == 0 ? "a=T,f=32,s=\(imageWidth),v=1,c=4,r=4,z=\(z),q=2,m=\(more)" : "m=\(more)"
                let chunk = String(decoding: encoded[offset..<end], as: UTF8.self)
                emulator.feed(Data("\u{1b}_G\(options);\(chunk)\u{1b}\\".utf8))
            }
            emulator.feed(Data("\u{1b}[H\u{1b}[44m \u{1b}[0m".utf8))
            let graphics = emulator.graphicsFrame(scrollOffset: 0, cellSize: renderer.cellSize, now: 0)
            XCTAssertEqual(graphics.placements.count, 1)
            renderer.updateImages(graphics, viewportSize: size, contentRect: content)
            renderer.update(state: emulator.state.activeScreen, scrollback: emulator.state.scrollback, scrollOffset: 0, viewportSize: size, contentRect: content)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
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
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                var result = [UInt8](repeating: 0, count: 4)
                target.getBytes(&result, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                return result
            }
            let cell = pixel(9, 9)
            if z < -1073741824 { XCTAssertGreaterThan(cell[0], cell[2]) }
            else { XCTAssertEqual(cell, [0, 0, 255, 255]) }
            XCTAssertEqual(pixel(8 + Int(renderer.cellSize.width * 3), 9), [0, 0, 255, 255])
            XCTAssertNotEqual(pixel(2, 2), [0, 0, 255, 255])
            XCTAssertNotEqual(pixel(80, 80), [0, 0, 255, 255])
        }
    }
    func testCroppedTransparentImageAtRetinaScales() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for scale in [CGFloat(1), 2, 3] {
            let renderer = TerminalMetalRenderer(device: device, scaleFactor: scale)
            let terminal = GhosttyTerminalEmulator(columns: 6, rows: 4)
            let size = CGSize(width: 128, height: 128)
            let content = CGRect(x: 8, y: 8, width: 100, height: 100)
            let physicalCell = CGSize(width: renderer.cellSize.width * scale, height: renderer.cellSize.height * scale)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(128 * scale), height: Int(128 * scale), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            func render() throws -> TerminalGraphicsFrame {
                let frame = terminal.graphicsFrame(scrollOffset: 0, cellSize: physicalCell, now: 0)
                renderer.updateImages(frame, viewportSize: size, contentRect: content)
                renderer.update(state: terminal.state.activeScreen, scrollback: terminal.state.scrollback, scrollOffset: 0, viewportSize: size, contentRect: content)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let command = try XCTUnwrap(renderer.render(to: pass))
                command.waitUntilCompleted()
                XCTAssertNil(command.error)
                return frame
            }
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: 4)
                target.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                return bytes
            }
            terminal.feed(Data("\u{1b}[?25l\u{1b}[44m\u{1b}[2J\u{1b}[2;2H".utf8))
            _ = try render()
            let x = Int(content.minX * scale + physicalCell.width * 2)
            let y = Int(content.minY * scale + physicalCell.height * 1.5)
            let baseline = pixel(x, y)
            let payload = Data([0, 255, 0, 255, 255, 0, 0, 128]).base64EncodedString()
            terminal.feed(Data("\u{1b}_Ga=T,f=32,s=2,v=1,i=9,x=1,w=1,c=2,r=1,z=1;\(payload)\u{1b}\\".utf8))
            let frame = try render()
            XCTAssertEqual(frame.placements.first?.source, CGRect(x: 1, y: 0, width: 1, height: 1))
            let blended = pixel(x, y)
            for channel in 0..<3 {
                let foreground = channel == 2 ? 255 : 0
                let expected = (foreground * 128 + Int(baseline[channel]) * 127) / 255
                XCTAssertEqual(Int(blended[channel]), expected, accuracy: 1, "scale \(scale), channel \(channel)")
            }
            XCTAssertEqual(blended[3], 255)
            terminal.feed(Data("\u{1b}_Ga=d,d=I,i=9\u{1b}\\".utf8))
            XCTAssertTrue(try render().placements.isEmpty)
            XCTAssertEqual(pixel(x, y), baseline)
        }
    }

}
