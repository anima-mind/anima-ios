// GlassesPhotoCapture.swift — la POLÍTICA de la foto POV del adapter (DAT 1.0).
// El SDK 1.0 trae `Camera.photo` (captura standalone, experimental): sin stream
// de video, hasta resolución nativa → menos latencia y más calidad que sacar un
// frame del stream. La doc oficial ("Capture reliability") la declara menos
// fiable que el stream: el arranque falla de forma intermitente
// (`sessionSetupFailed`) y el siguiente intento suele funcionar. De ahí:
//   1. standalone;
//   2. si el ARRANQUE falló → UN reintento standalone (cámara NUEVA: una cámara
//      detenida queda invalidada, lo hace cada closure del adapter);
//   3. si sigue sin arrancar, o el device no lo soporta → el flujo viejo por
//      stream (stream.start → .streaming → capturePhoto(.jpeg)), conservado;
//   4. un fallo de CAPTURA (permiso, ocupada, salud del device) NO cae al
//      stream: es un error real que se le muestra al dueño.
// El adapter (App/Glasses/DATGlassesRuntime.swift) traduce `PhotoError` a
// `GlassesPhotoError`; esta lógica es testeable sin hardware.

import Foundation

public enum GlassesPhotoError: Error, Equatable, CustomStringConvertible {
    /// El capability no arrancó (`sessionSetupFailed`, timeout esperando
    /// `.started`, vuelta a `.stopped`): reintentable, luego fallback.
    case setupFailed(String)
    /// El device/firmware no ofrece la captura standalone (`serviceUnavailable`,
    /// `notReady`): directo al fallback por stream.
    case unsupported(String)
    /// Fallo real de captura: se propaga (sin fallback).
    case failed(String)
    /// Meta AI no concedió el permiso de cámara (o no respondió).
    case permissionDenied(String?)
    /// La cámara arrancó pero la foto no llegó a tiempo.
    case timeout
    /// Ya hay una captura en vuelo (máximo una: los resultados no traen id).
    case busy
    /// No hay cámara (sin sesión, `addCamera` nil).
    case unavailable(String)

    public var description: String {
        switch self {
        case .setupFailed(let why): return "la cámara de las gafas no arrancó (\(why))"
        case .unsupported(let why): return "foto directa no soportada (\(why))"
        case .failed(let why): return "la foto falló (\(why))"
        case .permissionDenied(let why): return "permiso de cámara denegado en Meta AI" + (why.map { " (\($0))" } ?? "")
        case .timeout: return "la foto no llegó a tiempo"
        case .busy: return "ya hay una foto en curso"
        case .unavailable(let why): return "la cámara de las gafas no está disponible (\(why))"
        }
    }
}

public enum GlassesPhotoCapture {
    /// Ruta que terminó entregando la foto (diagnóstico/tests).
    public enum Path: String, Sendable, Equatable { case standalone, standaloneRetry, stream }

    /// Ejecuta la política. `standalone` y `stream` deben usar cada uno una
    /// cámara NUEVA (addCamera) y soltarla al terminar.
    public static func capture(
        standalone: @Sendable () async throws -> Data,
        stream: @Sendable () async throws -> Data,
        onPath: (@Sendable (Path, String?) -> Void)? = nil
    ) async throws -> Data {
        var reason: String
        do {
            let data = try await standalone()
            onPath?(.standalone, nil)
            return data
        } catch GlassesPhotoError.setupFailed(let why) {
            reason = why
            do {
                let data = try await standalone()
                onPath?(.standaloneRetry, why)
                return data
            } catch GlassesPhotoError.setupFailed(let again) {
                reason = again
            } catch GlassesPhotoError.unsupported(let why) {
                reason = why
            }
        } catch GlassesPhotoError.unsupported(let why) {
            reason = why
        }
        let data = try await stream()
        onPath?(.stream, reason)
        return data
    }
}
