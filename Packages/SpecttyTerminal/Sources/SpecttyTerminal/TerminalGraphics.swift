import Foundation
import CoreGraphics
import GhosttyVt

/// An owned copy of decoded image pixels; safe after native terminal mutations.
public struct TerminalImage: Sendable {
    public let generation: UInt64
    public let width: Int
    public let height: Int
    public let rgba: Data
}

public struct TerminalImagePlacement: Sendable {
    public let image: TerminalImage
    public let destination: CGRect
    public let source: CGRect
    /// 0: below backgrounds, 1: below text, 2: above text.
    public let layer: Int
    public let z: Int32
}

public struct TerminalGraphicsFrame: Sendable {
    public var placements: [TerminalImagePlacement] = []
    public var nextFrameDelay: TimeInterval?
}

extension GhosttyTerminalEmulator {
    public func graphicsFrame(scrollOffset: Int, cellSize: CGSize, now: TimeInterval) -> TerminalGraphicsFrame {
        var frame = TerminalGraphicsFrame()
        let width = UInt32(clamping: Int(max(1, cellSize.width.rounded())))
        let height = UInt32(clamping: Int(max(1, cellSize.height.rounded())))
        if pixelCellWidth != width || pixelCellHeight != height {
            guard ghostty_terminal_resize(terminal, UInt16(state.columns), UInt16(state.rows), width, height) == GHOSTTY_SUCCESS else { return frame }
            pixelCellWidth = width
            pixelCellHeight = height
        }
        var viewport = GhosttyTerminalScrollViewport()
        viewport.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
        viewport.value.row = max(0, scrollbackCount - max(0, scrollOffset))
        ghostty_terminal_scroll_viewport(terminal, viewport)
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS else { return frame }
        var next: UInt64 = 0
        let milliseconds = UInt64(max(0, now * 1000))
        if ghostty_kitty_graphics_animation_tick(graphics, milliseconds, &next) == GHOSTTY_SUCCESS {
            frame.nextFrameDelay = max(0.001, Double(next) / 1000 - now)
        }
        guard ghostty_render_state_update(nativeRender, terminal) == GHOSTTY_SUCCESS else { return frame }
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        if ghostty_render_state_get(nativeRender, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS {
            switch cursor.visual_style {
            case GHOSTTY_CURSOR_STYLE_BAR: state.activeScreen.cursor.style = .bar
            case GHOSTTY_CURSOR_STYLE_UNDERLINE: state.activeScreen.cursor.style = .underline
            default: state.activeScreen.cursor.style = .block
            }
        }
        guard ghostty_render_state_get(nativeRender, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &nativeImages) == GHOSTTY_SUCCESS else { return frame }
        var used = Set<UInt64>()
        while ghostty_render_state_image_iterator_next(nativeImages) {
            var imageID: UInt32 = 0
            var generation: UInt64 = 0
            var layer = GHOSTTY_IMAGE_LAYER_BELOW_BACKGROUND
            var z: Int32 = 0
            var column: Int32 = 0
            var row: Int32 = 0
            ghostty_render_state_image_get(nativeImages, GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID, &imageID)
            ghostty_render_state_image_get(nativeImages, GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, &generation)
            ghostty_render_state_image_get(nativeImages, GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER, &layer)
            ghostty_render_state_image_get(nativeImages, GHOSTTY_RENDER_STATE_IMAGE_DATA_Z, &z)
            ghostty_render_state_image_get(nativeImages, GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL, &column)
            ghostty_render_state_image_get(nativeImages, GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW, &row)
            let fields = [GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X, GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y,
                          GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH, GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT,
                          GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y,
                          GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT]
            let values: [CGFloat] = fields.map { field in
                var value: UInt32 = 0
                ghostty_render_state_image_get(nativeImages, field, &value)
                return CGFloat(value)
            }
            if imagePixels[generation] == nil, let image = ghostty_kitty_graphics_image(graphics, imageID) {
                var imageWidth: UInt32 = 0
                var imageHeight: UInt32 = 0
                var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
                var pixels = GhosttyString()
                ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &imageWidth)
                ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT, &imageHeight)
                ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT, &format)
                guard ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &pixels) == GHOSTTY_SUCCESS,
                      let bytes = pixels.ptr else { continue }
                let rgba: Data
                if format == GHOSTTY_KITTY_IMAGE_FORMAT_RGB {
                    var expanded = Data(count: Int(imageWidth) * Int(imageHeight) * 4)
                    expanded.withUnsafeMutableBytes { output in
                        let dst = output.bindMemory(to: UInt8.self)
                        for index in 0..<(Int(imageWidth) * Int(imageHeight)) {
                            dst[index * 4] = bytes[index * 3]
                            dst[index * 4 + 1] = bytes[index * 3 + 1]
                            dst[index * 4 + 2] = bytes[index * 3 + 2]
                            dst[index * 4 + 3] = 255
                        }
                    }
                    rgba = expanded
                } else {
                    rgba = Data(bytes: bytes, count: pixels.len)
                }
                imagePixels[generation] = TerminalImage(generation: generation, width: Int(imageWidth), height: Int(imageHeight), rgba: rgba)
            }
            guard let image = imagePixels[generation] else { continue }
            used.insert(generation)
            let layerIndex = layer == GHOSTTY_IMAGE_LAYER_BELOW_BACKGROUND ? 0 : layer == GHOSTTY_IMAGE_LAYER_BELOW_TEXT ? 1 : 2
            frame.placements.append(TerminalImagePlacement(
                image: image,
                destination: CGRect(x: CGFloat(column) * CGFloat(width) + values[0], y: CGFloat(row) * CGFloat(height) + values[1], width: values[2], height: values[3]),
                source: CGRect(x: values[4], y: values[5], width: values[6], height: values[7]),
                layer: layerIndex, z: z
            ))
        }
        imagePixels = imagePixels.filter { used.contains($0.key) }
        frame.placements.sort { $0.layer == $1.layer ? $0.z < $1.z : $0.layer < $1.layer }
        return frame
    }
}
