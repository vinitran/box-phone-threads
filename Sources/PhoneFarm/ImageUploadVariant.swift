import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageUploadVariant {
    /// Creates a temporary upload copy with 3–6 randomly positioned, one-pixel dots.
    /// The source file is read only; callers remove the temporary PNG after uploading.
    static func prepare(_ source: URL) throws -> URL {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              width * height <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else {
            throw ThreadsSettings.SettingsError("Không đọc được ảnh để tạo bản chuyển lên điện thoại: \(source.lastPathComponent).")
        }
        let pixelCount = image.width * image.height
        let dots = min(Int.random(in: 3...6), pixelCount)
        var positions = Set<Int>()
        while positions.count < dots { positions.insert(Int.random(in: 0..<pixelCount)) }
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        let outputImage: CGImage? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let buffer = bytes.bindMemory(to: UInt8.self)
            for position in positions {
                let offset = position * 4
                // Toggle between dark and light dots so each selected pixel actually changes.
                let color: UInt8 = Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2]) > 382 ? 24 : 232
                buffer[offset] = color
                buffer[offset + 1] = color
                buffer[offset + 2] = color
                buffer[offset + 3] = 255
            }
            return context.makeImage()
        }
        guard let outputImage else { throw ThreadsSettings.SettingsError("Không tạo được bản ảnh chuyển lên điện thoại.") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("phone-farm-upload-" + UUID().uuidString + ".png")
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ThreadsSettings.SettingsError("Không tạo được tệp ảnh tạm.")
        }
        CGImageDestinationAddImage(writer, outputImage, nil)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw ThreadsSettings.SettingsError("Không ghi được bản ảnh chuyển lên điện thoại.")
        }
        return destination
    }
}
