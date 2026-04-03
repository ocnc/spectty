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

/// Protocol for terminal renderers (allows swapping Metal impl for libghostty's renderer).
public protocol TerminalRenderer: AnyObject {
    func update(
        state: TerminalScreenState,
        scrollback: TerminalBuffer,
        scrollOffset: Int,
        viewportSize: CGSize,
        contentRect: CGRect
    )
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

/// Glyph cache key.
struct GlyphCacheKey: Hashable {
    var character: Character
    var fontName: String
    var widthMultiplier: Int
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

/// Resolved glyph source for a character.
private struct ResolvedGlyph {
    var fontName: String
    var scaledFont: CTFont
    var glyph: CGGlyph
}

/// Metal-based terminal renderer with glyph atlas.
public final class TerminalMetalRenderer: TerminalRenderer {
    private let device: MTLDevice
    private var pipelineState: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?

    // Glyph atlas
    private var atlasTexture: MTLTexture?
    private var glyphCache: [GlyphCacheKey: GlyphInfo] = [:]
    private var atlasNextX: Int = 0
    private var atlasNextY: Int = 0
    private var atlasRowHeight: Int = 0
    private let atlasWidth = 4096
    private let atlasHeight = 4096

    // Font
    private var font: CTFont             // 1x font for metrics
    private var scaledFont: CTFont       // scaled font for rasterization
    private var fallbackFontNames: [String] = []
    private var fallbackScaledFonts: [(name: String, font: CTFont)] = []
    private var _cellSize: CGSize = .zero
    public var cellSize: CGSize { _cellSize }
    private var _scaleFactor: CGFloat = 1.0

    // Vertex buffer
    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0

    // Theme
    private var theme: TerminalTheme = .default
    private var defaultFG: (UInt8, UInt8, UInt8) { theme.foreground }
    private var defaultBG: (UInt8, UInt8, UInt8) { theme.background }
    private var cursorColor: (UInt8, UInt8, UInt8) { theme.cursor }
    private var _cursorStyle: CursorStyle = .block

    public init(device: MTLDevice, scaleFactor: CGFloat) {
        self.device = device
        self._scaleFactor = scaleFactor
        self.commandQueue = device.makeCommandQueue()
        self.font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        self.scaledFont = CTFontCreateWithName("Menlo" as CFString, 14 * scaleFactor, nil)
        rebuildFallbackFonts(for: 14)
        computeCellSize()
        buildAtlas()
        buildPipeline()
    }

    /// Update scale factor (e.g., when moving between screens).
    public func setScaleFactor(_ scale: CGFloat) {
        guard scale != _scaleFactor else { return }
        _scaleFactor = scale
        let size = CTFontGetSize(font)
        scaledFont = CTFontCreateWithName(CTFontCopyPostScriptName(font), size * scale, nil)
        rebuildFallbackFonts(for: size)
        glyphCache.removeAll()
        atlasNextX = 0
        atlasNextY = 0
        atlasRowHeight = 0
        buildAtlas()
    }

    private var _currentFontName: String = "Menlo"
    private var _currentFontSize: CGFloat = 14

    public func setFont(_ termFont: TerminalFont) {
        guard termFont.name != _currentFontName || termFont.size != _currentFontSize else { return }
        _currentFontName = termFont.name
        _currentFontSize = termFont.size
        self.font = CTFontCreateWithName(termFont.name as CFString, termFont.size, nil)
        self.scaledFont = CTFontCreateWithName(termFont.name as CFString, termFont.size * _scaleFactor, nil)
        rebuildFallbackFonts(for: termFont.size)
        computeCellSize()
        glyphCache.removeAll()
        atlasNextX = 0
        atlasNextY = 0
        atlasRowHeight = 0
        buildAtlas()
    }

    public func setTheme(_ theme: TerminalTheme) {
        self.theme = theme
    }

    public func setCursorStyle(_ style: CursorStyle) {
        self._cursorStyle = style
    }

    // MARK: - Color Resolution

    /// Resolve a TerminalColor using the current theme's ANSI overrides for indices 0-15.
    private func resolveColor(_ color: TerminalColor, default defaultRGB: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
        switch color {
        case .default:
            return defaultRGB
        case .indexed(let idx):
            if idx < 16, Int(idx) < theme.ansiColors.count {
                return theme.ansiColors[Int(idx)]
            }
            return color.resolved(defaultColor: defaultRGB)
        case .rgb(let r, let g, let b):
            return (r, g, b)
        }
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

    private func rebuildFallbackFonts(for size: CGFloat) {
        let candidates = [
            ".PingFangSC-Regular",
            "PingFangSC-Regular",
            ".SFUI-Regular",
            "Helvetica"
        ]
        let primaryName = String(CTFontCopyPostScriptName(font))

        fallbackFontNames = candidates.filter { $0 != primaryName }
        fallbackScaledFonts = fallbackFontNames.map {
            ($0, CTFontCreateWithName($0 as CFString, size * _scaleFactor, nil))
        }
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

    private func glyphInfo(for char: Character, widthMultiplier: Int = 1) -> GlyphInfo {
        guard let resolved = resolveGlyph(for: char) else {
            return GlyphInfo(textureX: 0, textureY: 0, width: 0, height: 0, bearingX: 0, bearingY: 0)
        }

        let cacheKey = GlyphCacheKey(character: char, fontName: resolved.fontName, widthMultiplier: widthMultiplier)
        if let cached = glyphCache[cacheKey] {
            return cached
        }

        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(resolved.scaledFont, .horizontal, [resolved.glyph], &boundingRect, 1)

        let scale = _scaleFactor
        let bitmapWidth = max(Int(ceil(_cellSize.width * scale * CGFloat(widthMultiplier))), 1)
        let bitmapHeight = max(Int(ceil(_cellSize.height * scale)), 1)

        // Check if we need to move to the next row in the atlas.
        if atlasNextX + bitmapWidth > atlasWidth {
            atlasNextX = 0
            atlasNextY += atlasRowHeight
            atlasRowHeight = 0
        }

        if atlasNextY + bitmapHeight > atlasHeight {
            let info = GlyphInfo(textureX: 0, textureY: 0, width: 0, height: 0, bearingX: 0, bearingY: 0)
            glyphCache[cacheKey] = info
            return info
        }

        // Rasterize the glyph into a bitmap at native pixel resolution.
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
            glyphCache[cacheKey] = info
            return info
        }

        let scaledAscent = CTFontGetAscent(resolved.scaledFont)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

        context.setFillColor(gray: 1, alpha: 1)
        context.textMatrix = .identity

        let position = CGPoint(x: -boundingRect.origin.x, y: CGFloat(bitmapHeight) - scaledAscent)
        CTFontDrawGlyphs(resolved.scaledFont, [resolved.glyph], [position], 1, context)

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
            bearingX: Float(boundingRect.origin.x / scale),
            bearingY: Float(scaledAscent / scale)
        )

        glyphCache[cacheKey] = info
        atlasNextX += bitmapWidth
        atlasRowHeight = max(atlasRowHeight, bitmapHeight)

        return info
    }

    private func resolveGlyph(for char: Character) -> ResolvedGlyph? {
        let utf16 = Array(String(char).utf16)
        guard utf16.count == 1 else {
            return resolveGlyph(from: utf16, with: String(CTFontCopyPostScriptName(scaledFont)), font: scaledFont)
        }

        if let resolved = resolveGlyph(from: utf16, with: String(CTFontCopyPostScriptName(scaledFont)), font: scaledFont) {
            return resolved
        }

        for fallback in fallbackScaledFonts {
            if let resolved = resolveGlyph(from: utf16, with: fallback.name, font: fallback.font) {
                return resolved
            }
        }

        return nil
    }

    private func resolveGlyph(from utf16: [UniChar], with fontName: String, font: CTFont) -> ResolvedGlyph? {
        var chars = utf16
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        let mapped = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        guard mapped, let glyph = glyphs.first, glyph != 0 else {
            return nil
        }
        return ResolvedGlyph(fontName: fontName, scaledFont: font, glyph: glyph)
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

    public func update(
        state: TerminalScreenState,
        scrollback: TerminalBuffer,
        scrollOffset: Int,
        viewportSize: CGSize,
        contentRect: CGRect
    ) {
        // Build vertex data for all visible cells.
        var vertices: [CellVertex] = []
        vertices.reserveCapacity(state.columns * state.rows * 6) // 6 vertices per cell (2 triangles)

        // Use actual viewport size for clip-space mapping so content stays
        // at its natural pixel position during view resize animations
        // instead of stretching to fill the drawable.
        let viewW = max(Float(viewportSize.width), 1)
        let viewH = max(Float(viewportSize.height), 1)
        let cellW = Float(_cellSize.width)
        let cellH = Float(_cellSize.height)
        let originX = Float(contentRect.minX)
        let originY = Float(contentRect.minY)

        for row in 0..<state.rows {
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

            var col = 0
            while col < min(state.columns, line.cells.count) {
                let cell = line.cells[col]
                if cell.isWideTail {
                    col += 1
                    continue
                }

                let span = cell.isWideHead ? 2 : 1

                // Resolve colors using theme palette.
                let isInverse = cell.attributes.contains(.inverse)
                var fgRGB = resolveColor(cell.fg, default: defaultFG)
                var bgRGB = resolveColor(cell.bg, default: defaultBG)
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
                let x0 = originX + Float(col) * cellW
                let y0 = originY + Float(row) * cellH
                let backgroundX1 = x0 + cellW * Float(span)
                let glyphX1 = backgroundX1
                let y1 = y0 + cellH

                // Normalize to clip space [-1, 1].
                let bgCX0 = (x0 / viewW) * 2.0 - 1.0
                let bgCY0 = 1.0 - (y0 / viewH) * 2.0
                let bgCX1 = (backgroundX1 / viewW) * 2.0 - 1.0
                let bgCY1 = 1.0 - (y1 / viewH) * 2.0

                let glyphCX0 = (x0 / viewW) * 2.0 - 1.0
                let glyphCY0 = 1.0 - (y0 / viewH) * 2.0
                let glyphCX1 = (glyphX1 / viewW) * 2.0 - 1.0
                let glyphCY1 = 1.0 - (y1 / viewH) * 2.0

                // Draw background across the full occupied width.
                let zeroUV = SIMD2<Float>(0, 0)
                vertices.append(CellVertex(position: SIMD2(bgCX0, bgCY0), texCoord: zeroUV, fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(bgCX1, bgCY0), texCoord: zeroUV, fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(bgCX0, bgCY1), texCoord: zeroUV, fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(bgCX1, bgCY0), texCoord: zeroUV, fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(bgCX1, bgCY1), texCoord: zeroUV, fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(bgCX0, bgCY1), texCoord: zeroUV, fgColor: fgColor, bgColor: bgColor))

                // Get glyph info for this character.
                let glyph = glyphInfo(for: cell.character, widthMultiplier: span)
                let atlasW = Float(atlasWidth)
                let atlasH = Float(atlasHeight)
                let u0 = Float(glyph.textureX) / atlasW
                let v0 = Float(glyph.textureY) / atlasH
                let u1 = Float(glyph.textureX + glyph.width) / atlasW
                let v1 = Float(glyph.textureY + glyph.height) / atlasH

                // Match the glyph quad to the character span. For wide glyphs, the
                // atlas entry is rasterized into a 2-cell bitmap and should be
                // sampled across the full 2-cell quad instead of being squeezed
                // into a single cell.
                vertices.append(CellVertex(position: SIMD2(glyphCX0, glyphCY0), texCoord: SIMD2(u0, v0), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(glyphCX1, glyphCY0), texCoord: SIMD2(u1, v0), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(glyphCX0, glyphCY1), texCoord: SIMD2(u0, v1), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(glyphCX1, glyphCY0), texCoord: SIMD2(u1, v0), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(glyphCX1, glyphCY1), texCoord: SIMD2(u1, v1), fgColor: fgColor, bgColor: bgColor))
                vertices.append(CellVertex(position: SIMD2(glyphCX0, glyphCY1), texCoord: SIMD2(u0, v1), fgColor: fgColor, bgColor: bgColor))

                col += span
            }
        }

        // Cursor rendering.
        if scrollOffset == 0 && state.cursor.visible {
            let cursorRow = state.cursor.row
            var cursorCol = state.cursor.col
            if cursorRow >= 0 && cursorRow < state.rows && cursorCol >= 0 && cursorCol < state.columns {
                let line = state.lines[cursorRow]
                if cursorCol < line.cells.count, line.cells[cursorCol].isWideTail {
                    cursorCol -= 1
                }
                let cursorCell = line.cells[cursorCol]
                let cursorSpan = cursorCell.isWideHead ? 2 : 1
                let x0 = originX + Float(cursorCol) * cellW
                let y0 = originY + Float(cursorRow) * cellH

                // Compute cursor rect based on style.
                let cursorX0: Float
                let cursorY0: Float
                let cursorX1: Float
                let cursorY1: Float

                switch _cursorStyle {
                case .block:
                    cursorX0 = x0
                    cursorY0 = y0
                    cursorX1 = x0 + cellW * Float(cursorSpan)
                    cursorY1 = y0 + cellH
                case .underline:
                    let thickness = max(cellH * 0.1, 2.0)
                    cursorX0 = x0
                    cursorY0 = y0 + cellH - thickness
                    cursorX1 = x0 + cellW * Float(cursorSpan)
                    cursorY1 = y0 + cellH
                case .bar:
                    let thickness = max(cellW * 0.12, 2.0)
                    cursorX0 = x0
                    cursorY0 = y0
                    cursorX1 = x0 + thickness
                    cursorY1 = y0 + cellH
                }

                let cx0 = (cursorX0 / viewW) * 2.0 - 1.0
                let cy0 = 1.0 - (cursorY0 / viewH) * 2.0
                let cx1 = (cursorX1 / viewW) * 2.0 - 1.0
                let cy1 = 1.0 - (cursorY1 / viewH) * 2.0

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
                    _cursorStyle == .block ? 0.85 : 1.0
                )

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
        constexpr sampler s(mag_filter::nearest, min_filter::nearest);
        float glyphAlpha = glyphAtlas.sample(s, in.texCoord).r;

        // Composite: glyph foreground over background.
        float4 color = mix(in.bgColor, in.fgColor, glyphAlpha);
        return color;
    }
    """
}
