import Foundation
import CoreGraphics
import ImageIO
import GhosttyVt

extension GhosttyTerminalEmulator {
    static let configurePNG: Void = {
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decodePNG as GhosttySysDecodePngFn, to: UnsafeRawPointer.self))
    }()
}

private func decodePNG(_ context: UnsafeMutableRawPointer?, _ allocator: UnsafePointer<GhosttyAllocator>?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ output: UnsafeMutablePointer<GhosttySysImage>?) -> Bool {
    guard let bytes, let output, count >= 8,
          Array(UnsafeBufferPointer(start: bytes, count: 8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { return false }
    let data = Data(bytes: bytes, count: count)
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          (1...10_000).contains(width), (1...10_000).contains(height) else { return false }
    let length = width * height * 4
    // Allocate through Ghostty before decoding so its per-image memory budget is enforced.
    guard let pixels = ghostty_alloc(allocator, length) else { return false }
    pixels.initialize(repeating: 0, count: length)
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
          image.width == width, image.height == height,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let bitmap = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
        ghostty_free(allocator, pixels, length)
        return false
    }
    bitmap.setBlendMode(.copy)
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Kitty pixels use straight alpha; Core Graphics produces premultiplied components.
    for offset in stride(from: 0, to: length, by: 4) {
        let alpha = Int(pixels[offset + 3])
        if alpha > 0 && alpha < 255 {
            for component in 0..<3 {
                pixels[offset + component] = UInt8(min(255, (Int(pixels[offset + component]) * 255 + alpha / 2) / alpha))
            }
        }
    }
    output.pointee = GhosttySysImage(width: UInt32(width), height: UInt32(height), data: pixels, data_len: length)
    return true
}
