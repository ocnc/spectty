import Foundation
import Metal
import MetalKit
import CoreText
import UIKit
import SpecttyTerminal

/// Font configuration for the terminal.
public struct TerminalFont: Sendable {
    public var name: String
    public var size: CGFloat

    public init(name: String = "Menlo", size: CGFloat = 14) {
        self.name = name
        self.size = size
    }
}

/// Protocol for terminal renderers (allows swapping Metal impl for libghostty's renderer later).
public protocol TerminalRenderer: AnyObject {
    func update(state: TerminalScreenState, scrollback: TerminalBuffer, scrollOffset: Int)
    func setFont(_ font: TerminalFont)
    var cellSize: CGSize { get }
}

/// Vertex structure matching the Metal shader.
struct CellVertex {
    var position: SIMD2<Float>       // Clip-space position
    var texCoord: SIMD2<Float>       // Glyph atlas UV
    var fgColor: SIMD4<Float>        // Foreground RGBA
    var bgColor: SIMD4<Float>        // Background RGBA
}

/// Uniform buffer for the vertex shader.
struct TerminalUniforms {
    var viewportSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var gridSize: SIMD2<UInt32>     // columns, rows
    var atlasSize: SIMD2<Float>
}

/// Glyph cache entry.
struct GlyphInfo {
    var textureX: Int
    var textureY: Int
    var width: Int
    var height: Int
    var bearingX: Float
    var bearingY: Float
}

/// Metal-based terminal renderer with glyph atlas.
public final class TerminalMetalRenderer: TerminalRenderer {
    private let device: MTLDevice
    private var pipelineState: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?

    // Glyph atlas
    private var atlasTexture: MTLTexture?
    private var glyphCache: [Character: GlyphInfo] = [:]
    private var atlasNextX: Int = 0
    private var atlasNextY: Int = 0
    private var atlasRowHeight: Int = 0
    private let atlasWidth = 2048
    private let atlasHeight = 2048

    // Font
    private var font: CTFont
    private var _cellSize: CGSize = .zero
    public var cellSize: CGSize { _cellSize }

    // Vertex buffer
    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0

    // Theme colors
    private var defaultFG: (UInt8, UInt8, UInt8) = (229, 229, 229)
    private var defaultBG: (UInt8, UInt8, UInt8) = (30, 30, 30)
    private var cursorColor: (UInt8, UInt8, UInt8) = (229, 229, 229)

    public init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        computeCellSize()
        buildAtlas()
        buildPipeline()
    }

    public func setFont(_ termFont: TerminalFont) {
        if let ctFont = CTFont(termFont.name as CFString, size: termFont.size) as CTFont? {
            self.font = ctFont
        } else {
            self.font = CTFontCreateWithName("Menlo" as CFString, termFont.size, nil)
        }
        computeCellSize()
        glyphCache.removeAll()
        atlasNextX = 0
        atlasNextY = 0
        atlasRowHeight = 0
        buildAtlas()
    }

    // MARK: - Cell Size Computation

    private func computeCellSize() {
        // Use "M" to get the advance width.
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        let mChar: [UniChar] = [0x4D] // 'M'
        CTFontGetGlyphsForCharacters(font, mChar, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, [glyph], &advance, 1)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        _cellSize = CGSize(
            width: ceil(advance.width > 0 ? advance.width : 8),
            height: ceil(ascent + descent + leading)
        )
    }

    // MARK: - Glyph Atlas

    private func buildAtlas() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        atlasTexture = device.makeTexture(descriptor: descriptor)

        // Pre-rasterize ASCII printable characters.
        for code in 0x20...0x7E {
            let char = Character(UnicodeScalar(code)!)
            _ = glyphInfo(for: char)
        }
    }

    private func glyphInfo(for char: Character) -> GlyphInfo {
        if let cached = glyphCache[char] {
            return cached
        }

        let scalars = Array(char.unicodeScalars)
        var unichars = scalars.map { UniChar($0.value) }
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)

        let glyph = glyphs[0]
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, [glyph], &boundingRect, 1)

        let glyphWidth = max(Int(ceil(boundingRect.width)), 1)
        let glyphHeight = max(Int(ceil(_cellSize.height)), 1)

        // Check if we need to move to the next row in the atlas.
        if atlasNextX + glyphWidth > atlasWidth {
            atlasNextX = 0
            atlasNextY += atlasRowHeight
            atlasRowHeight = 0
        }

        if atlasNextY + glyphHeight > atlasHeight {
            // Atlas is full. In a real implementation we'd allocate a new atlas.
            let info = GlyphInfo(textureX: 0, textureY: 0, width: 0, height: 0, bearingX: 0, bearingY: 0)
            glyphCache[char] = info
            return info
        }

        // Rasterize the glyph into a bitmap.
        let bitmapWidth = Int(_cellSize.width)
        let bitmapHeight = glyphHeight
        var pixelData = [UInt8](repeating: 0, count: bitmapWidth * bitmapHeight)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixelData,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bitmapWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            let info = GlyphInfo(textureX: 0, textureY: 0, width: 0, height: 0, bearingX: 0, bearingY: 0)
            glyphCache[char] = info
            return info
        }

        let ascent = CTFontGetAscent(font)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

        context.setFillColor(gray: 1, alpha: 1)
        context.textMatrix = .identity

        let position = CGPoint(x: -boundingRect.origin.x, y: CGFloat(bitmapHeight) - ascent)
        CTFontDrawGlyphs(font, [glyph], [position], 1, context)

        // Upload to atlas texture.
        let region = MTLRegion(
            origin: MTLOrigin(x: atlasNextX, y: atlasNextY, z: 0),
            size: MTLSize(width: bitmapWidth, height: bitmapHeight, depth: 1)
        )
        atlasTexture?.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bitmapWidth
        )

        let info = GlyphInfo(
            textureX: atlasNextX,
            textureY: atlasNextY,
            width: bitmapWidth,
            height: bitmapHeight,
            bearingX: Float(boundingRect.origin.x),
            bearingY: Float(ascent)
        )

        glyphCache[char] = info
        atlasNextX += bitmapWidth
        atlasRowHeight = max(atlasRowHeight, bitmapHeight)

        return info
    }

    // MARK: - Metal Pipeline

    private func buildPipeline() {
        let shaderSource = Self.metalShaderSource

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            return
        }

        let vertexFunction = library.makeFunction(name: "terminalVertexShader")
        let fragmentFunction = library.makeFunction(name: "terminalFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable alpha blending for text rendering.
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // MARK: - Update State

    public func update(state: TerminalScreenState, scrollback: TerminalBuffer, scrollOffset: Int) {
        // Build vertex data for all visible cells.
        var vertices: [CellVertex] = []
        vertices.reserveCapacity(state.columns * state.rows * 6) // 6 vertices per cell (2 triangles)

        let viewW = Float(state.columns) * Float(_cellSize.width)
        let viewH = Float(state.rows) * Float(_cellSize.height)
        let cellW = Float(_cellSize.width)
        let cellH = Float(_cellSize.height)

        for row in 0..<state.rows {
            let lineIndex: Int
            let line: TerminalLine

            if scrollOffset > 0 {
                // We're scrolled into scrollback.
                let scrollbackRow = scrollback.count - scrollOffset + row
                if scrollbackRow < 0 || scrollbackRow >= scrollback.count {
                    // Showing screen line.
                    let screenRow = row - scrollOffset + (scrollOffset > state.rows ? state.rows : 0)
                    if screenRow >= 0 && screenRow < state.rows {
                        line = state.lines[screenRow]
                    } else {
                        continue
                    }
                } else {
                    if let sbLine = scrollback.line(at: scrollbackRow) {
                        line = sbLine
                    } else {
                        continue
                    }
                }
            } else {
                line = state.lines[row]
            }

            for col in 0..<min(state.columns, line.cells.count) {
                let cell = line.cells[col]

                // Resolve colors.
                let isInverse = cell.attributes.contains(.inverse)
                var fgRGB = cell.fg.resolved(defaultColor: defaultFG)
                var bgRGB = cell.bg.resolved(defaultColor: defaultBG)
                if isInverse {
                    swap(&fgRGB, &bgRGB)
                }
                if cell.attributes.contains(.dim) {
                    fgRGB = (fgRGB.0 / 2, fgRGB.1 / 2, fgRGB.2 / 2)
                }

                let fgColor = SIMD4<Float>(
                    Float(fgRGB.0) / 255.0,
                    Float(fgRGB.1) / 255.0,
                    Float(fgRGB.2) / 255.0,
                    1.0
                )
                let bgColor = SIMD4<Float>(
                    Float(bgRGB.0) / 255.0,
                    Float(bgRGB.1) / 255.0,
                    Float(bgRGB.2) / 255.0,
                    1.0
                )

                // Position in pixel coordinates (top-left origin).
                let x0 = Float(col) * cellW
                let y0 = Float(row) * cellH
                let x1 = x0 + cellW
                let y1 = y0 + cellH

                // Normalize to clip space [-1, 1].
                let cx0 = (x0 / viewW) * 2.0 - 1.0
                let cy0 = 1.0 - (y0 / viewH) * 2.0
                let cx1 = (x1 / viewW) * 2.0 - 1.0
                let cy1 = 1.0 - (y1 / viewH) * 2.0

                // Get glyph info for this character.
                let glyph = glyphInfo(for: cell.character)
                let atlasW = Float(atlasWidth)
                let atlasH = Float(atlasHeight)
                let u0 = Float(glyph.textureX) / atlasW
                let v0 = Float(glyph.textureY) / atlasH
                let u1 = Float(glyph.textureX + glyph.width) / atlasW
                let v1 = Float(glyph.textureY + glyph.height) / atlasH

                // Two triangles per cell.
                // Triangle 1: top-left, top-right, bottom-left
                vertices.append(CellVertex(position: SIMD2(cx0, cy0), texCoord: SIMD2(u0, v0), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(cx1, cy0), texCoord: SIMD2(u1, v0), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(cx0, cy1), texCoord: SIMD2(u0, v1), fgColor: fgColor, bgColor: bgColor))
                // Triangle 2: top-right, bottom-right, bottom-left
                vertices.append(CellVertex(position: SIMD2(cx1, cy0), texCoord: SIMD2(u1, v0), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(cx1, cy1), texCoord: SIMD2(u1, v1), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(cx0, cy1), texCoord: SIMD2(u0, v1), fgColor: fgColor, bgColor: bgColor))
            }
        }

        // Cursor rendering.
        if scrollOffset == 0 && state.cursor.visible {
            let cursorRow = state.cursor.row
            let cursorCol = state.cursor.col
            if cursorRow >= 0 && cursorRow < state.rows && cursorCol >= 0 && cursorCol < state.columns {
                let x0 = Float(cursorCol) * cellW
                let y0 = Float(cursorRow) * cellH
                let x1 = x0 + cellW
                let y1 = y0 + cellH

                let cx0 = (x0 / viewW) * 2.0 - 1.0
                let cy0 = 1.0 - (y0 / viewH) * 2.0
                let cx1 = (x1 / viewW) * 2.0 - 1.0
                let cy1 = 1.0 - (y1 / viewH) * 2.0

                let cursorFG = SIMD4<Float>(
                    Float(defaultBG.0) / 255.0,
                    Float(defaultBG.1) / 255.0,
                    Float(defaultBG.2) / 255.0,
                    1.0
                )
                let cursorBG = SIMD4<Float>(
                    Float(cursorColor.0) / 255.0,
                    Float(cursorColor.1) / 255.0,
                    Float(cursorColor.2) / 255.0,
                    0.85
                )

                // No glyph for cursor overlay — use zero UV.
                let zeroUV = SIMD2<Float>(0, 0)

                vertices.append(CellVertex(position: SIMD2(cx0, cy0), texCoord: zeroUV, fgColor: cursorFG, bgColor: cursorBG))
                vertices.append(CellVertex(position: SIMD2(cx1, cy0), texCoord: zeroUV, fgColor: cursorFG, bgColor: cursorBG))
                vertices.append(CellVertex(position: SIMD2(cx0, cy1), texCoord: zeroUV, fgColor: cursorFG, bgColor: cursorBG))
                vertices.append(CellVertex(position: SIMD2(cx1, cy0), texCoord: zeroUV, fgColor: cursorFG, bgColor: cursorBG))
                vertices.append(CellVertex(position: SIMD2(cx1, cy1), texCoord: zeroUV, fgColor: cursorFG, bgColor: cursorBG))
                vertices.append(CellVertex(position: SIMD2(cx0, cy1), texCoord: zeroUV, fgColor: cursorFG, bgColor: cursorBG))
            }
        }

        vertexCount = vertices.count
        if vertexCount > 0 {
            vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<CellVertex>.stride,
                options: .storageModeShared
            )
        }
    }

    // MARK: - Render

    func render(to renderPassDescriptor: MTLRenderPassDescriptor, drawable: MTLDrawable) {
        guard let pipelineState = pipelineState,
              let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }

        // Clear with background color.
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(defaultBG.0) / 255.0,
            green: Double(defaultBG.1) / 255.0,
            blue: Double(defaultBG.2) / 255.0,
            alpha: 1.0
        )

        encoder.setRenderPipelineState(pipelineState)

        if let vertexBuffer = vertexBuffer, vertexCount > 0 {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            if let atlas = atlasTexture {
                encoder.setFragmentTexture(atlas, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Metal Shader Source

    static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellVertex {
        float2 position;
        float2 texCoord;
        float4 fgColor;
        float4 bgColor;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float4 fgColor;
        float4 bgColor;
    };

    vertex VertexOut terminalVertexShader(
        const device CellVertex *vertices [[buffer(0)]],
        uint vid [[vertex_id]])
    {
        VertexOut out;
        out.position = float4(vertices[vid].position, 0.0, 1.0);
        out.texCoord = vertices[vid].texCoord;
        out.fgColor = vertices[vid].fgColor;
        out.bgColor = vertices[vid].bgColor;
        return out;
    }

    fragment float4 terminalFragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> glyphAtlas [[texture(0)]])
    {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float glyphAlpha = glyphAtlas.sample(s, in.texCoord).r;

        // Composite: glyph foreground over background.
        float4 color = mix(in.bgColor, in.fgColor, glyphAlpha);
        return color;
    }
    """
}
