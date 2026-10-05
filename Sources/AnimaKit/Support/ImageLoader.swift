// ImageLoader.swift — decode de fotos del chat FUERA del main thread (campo
// batch 3, FIX G). Las fotos del historial salen del SymbolicStore (JPEG en
// base64): un UIImage(data:) síncrono en el body de la celda congela el scroll.
// Las celdas usan un thumbnail reducido con ImageIO (CGImageSource, sin
// decodificar la imagen completa); el visor carga la resolución completa async.

import Foundation
import CoreGraphics
import ImageIO

public enum ImageLoader {
    /// Lado máximo (px) del thumb de una celda del chat (3× de ~160 pt).
    public static let thumbMaxPixel = 480

    /// Thumbnail acotado a `maxPixel` en su lado mayor (respeta la orientación EXIF).
    public static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Imagen completa, decodificada ya (no perezosa: el primer frame no tironea).
    public static func full(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0,
                                               [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Síncrono a propósito: lo llama el Task detached (fuera del main).
    private static func decode(_ data: Data, maxPixel: Int?,
                               onDecode: (@Sendable (Bool) -> Void)?) -> CGImage? {
        onDecode?(Thread.isMainThread)
        return maxPixel.map { thumbnail(data, maxPixel: $0) } ?? full(data)
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Decode async en un Task detached (jamás en el actor que llama, típicamente
    /// el main). `maxPixel` nil ⇒ resolución completa (visor). Cachea por
    /// contenido+tamaño. `onDecode` (tests) recibe si el decode corrió en main.
    public static func load(_ data: Data, maxPixel: Int?,
                            onDecode: (@Sendable (_ onMainThread: Bool) -> Void)? = nil) async -> CGImage? {
        let key = "\(data.count)-\(data.hashValue)-\(maxPixel ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            decode(data, maxPixel: maxPixel, onDecode: onDecode)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
