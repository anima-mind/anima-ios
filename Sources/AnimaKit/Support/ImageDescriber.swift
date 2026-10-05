// ImageDescriber.swift — Solo-teléfono (FoundationModels) no ve imágenes (campo
// batch 3, FIX G). Si hay una foto adjunta al enviar en ese modo, NO se manda
// en silencio ni falla: va como descripción de texto, con etiquetas que Vision
// detecta en el teléfono (on-device, sin red), y el dueño lo ve avisado.

import Foundation
#if canImport(Vision)
import Vision
#endif

public enum ImageDescriber {
    public static let notice = "Esta foto irá como descripción de texto: el modelo local no ve imágenes."

    /// El bloque de texto que reemplaza a la foto en el turno.
    public static func textBlock(labels: [String]) -> String {
        guard !labels.isEmpty else {
            return "[El dueño adjuntó una foto; el modelo local no puede verla y no se detectó contenido. Díselo con honestidad y pídele que la describa.]"
        }
        return "[El dueño adjuntó una foto que el modelo local no puede ver. Etiquetas detectadas en el teléfono (Vision): \(labels.joined(separator: ", ")). No inventes detalles más allá de esto.]"
    }

    /// Etiquetas de Vision (≥ `minConfidence`, máx `limit`). Vacío si no hay Vision.
    public static func labels(for data: Data, limit: Int = 6, minConfidence: Float = 0.3) async -> [String] {
        #if canImport(Vision)
        guard let image = ImageLoader.thumbnail(data, maxPixel: 768) else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            let observations = (request.results ?? [])
                .filter { $0.confidence >= minConfidence }
                .sorted { $0.confidence > $1.confidence }
            return observations.prefix(limit).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        }.value
        #else
        return []
        #endif
    }
}
