// HUDGlyphImages.swift — glifos propios del HUD (campo batch 6): el DAT de las
// gafas pinta el placeholder "sol" para casi todo el catálogo IconName, así que
// los iconos sueltos viajan como imagen: SF Symbol en blanco sobre transparente,
// 48×48 px a escala 1 (el display es 600×600; más grande solo añade latencia BT).
// El SDK 1.0.0 codifica el UIImage (PNG) en `Image(image:sizePreset:)`.

#if canImport(UIKit)
import UIKit

enum HUDGlyphImages {
    static let side: CGFloat = 48
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: UIImage] = [:]

    /// El glifo renderizado (cacheado por símbolo). nil si el símbolo no existe.
    static func image(symbol: String) -> UIImage? {
        lock.lock()
        if let cached = cache[symbol] { lock.unlock(); return cached }
        lock.unlock()
        guard let rendered = render(symbol) else { return nil }
        lock.lock(); cache[symbol] = rendered; lock.unlock()
        return rendered
    }

    static func render(_ symbol: String) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: side * 0.7, weight: .medium)
        guard let glyph = UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let canvas = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let size = glyph.size
            guard size.width > 0, size.height > 0 else { return }
            let fit = min(side * 0.85 / size.width, side * 0.85 / size.height, 1)
            let drawn = CGSize(width: size.width * fit, height: size.height * fit)
            glyph.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
    }
}
#endif
