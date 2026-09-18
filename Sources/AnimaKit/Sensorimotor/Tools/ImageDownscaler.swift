// ImageDownscaler.swift — pipeline PURO de imagen (§5.7): downscale al lado largo
// ≤1568px + JPEG + base64 → image block. Sin hardware: usa ImageIO/CoreGraphics
// (disponibles en macOS), por lo que es testeable en `swift test` con un fixture.
//
// Decisión de costo (§5.7): 1568px lado largo. Opus 4.8 soporta hasta 2576px a
// ~3× tokens de imagen — subir solo si la fidelidad lo pide.

import Foundation

#if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ImageDownscaler {
    public static let maxLongSide = 1568
    public static let mediaType = "image/jpeg"

    public struct Output: Sendable, Equatable {
        public var base64: String
        public var mediaType: String
        public var pixelWidth: Int
        public var pixelHeight: Int
    }

    /// Downscalea al lado largo ≤ `maxLongSide` y re-encoda a JPEG. Devuelve el
    /// base64 y las dimensiones resultantes. `nil` si el dato no es una imagen.
    public static func process(_ data: Data, maxLongSide: Int = maxLongSide, quality: Double = 0.8) -> Output? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Output(base64: (out as Data).base64EncodedString(),
                      mediaType: mediaType, pixelWidth: cg.width, pixelHeight: cg.height)
    }

    /// Construye directamente el image block para el mensaje user del turno.
    public static func imageBlock(from data: Data, maxLongSide: Int = maxLongSide, quality: Double = 0.8) -> ContentBlock? {
        guard let output = process(data, maxLongSide: maxLongSide, quality: quality) else { return nil }
        return .image(mediaType: output.mediaType, base64: output.base64)
    }
}
#else
public enum ImageDownscaler {
    public static let maxLongSide = 1568
    public static let mediaType = "image/jpeg"
    public struct Output: Sendable, Equatable {
        public var base64: String
        public var mediaType: String
        public var pixelWidth: Int
        public var pixelHeight: Int
    }
    public static func process(_ data: Data, maxLongSide: Int = maxLongSide, quality: Double = 0.8) -> Output? { nil }
    public static func imageBlock(from data: Data, maxLongSide: Int = maxLongSide, quality: Double = 0.8) -> ContentBlock? { nil }
}
#endif
