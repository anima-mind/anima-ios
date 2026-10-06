// GlassesConcurrency.swift — primitivas para puentear los callbacks del DAT SDK
// (listeners en cualquier hilo, que pueden repetirse) a async/await SIN las dos
// formas de crash de una continuation: resumirla dos veces (trap) o no
// resumirla nunca (la tarea queda colgada para siempre).

import Foundation

/// Resuelve UNA sola vez. `fire` antes de `set` queda pendiente y se entrega al
/// instalar el handler (la cancelación puede llegar antes que la continuation).
public final class GlassesOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((T) -> Void)?
    private var pending: T?
    private var resolved = false

    public init() {}

    public func set(_ handler: @escaping (T) -> Void) {
        lock.lock()
        if resolved, let value = pending {
            pending = nil
            lock.unlock()
            handler(value)
            return
        }
        self.handler = handler
        lock.unlock()
    }

    /// true solo para el primer valor; los siguientes se descartan.
    @discardableResult
    public func fire(_ value: T) -> Bool {
        lock.lock()
        guard !resolved else { lock.unlock(); return false }
        resolved = true
        guard let handler else { pending = value; lock.unlock(); return true }
        self.handler = nil
        lock.unlock()
        handler(value)
        return true
    }

    public var isResolved: Bool { lock.lock(); defer { lock.unlock() }; return resolved }
}

/// Bandera atómica (listeners del SDK llegan en cualquier hilo).
public final class GlassesFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func set() { lock.lock(); value = true; lock.unlock() }
    /// true solo para el primero que la levanta.
    public func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// Espera una tarea con tope: al vencer (o si cancelan al que espera) se
/// devuelve el control YA y se cancela la tarea, sin esperar a que el SDK
/// coopere. Así ninguna pantalla del HUD depende de que el hardware responda.
public enum GlassesDeadline {
    public static func wait<T: Sendable>(_ task: Task<T, Error>, timeout: TimeInterval,
                                         timeoutError: @escaping @Sendable () -> Error) async throws -> T {
        let once = GlassesOnce<Result<T, Error>>()
        let nanos = UInt64(max(0, timeout) * 1_000_000_000)
        let timer = Task {
            try await Task.sleep(nanoseconds: nanos)
            if once.fire(.failure(timeoutError())) { task.cancel() }
        }
        let result: Result<T, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
                once.set { continuation.resume(returning: $0) }
                Task {
                    let value = await task.result
                    once.fire(value)
                }
            }
        } onCancel: {
            if once.fire(.failure(CancellationError())) { task.cancel() }
        }
        timer.cancel()
        return try result.get()
    }

    public static func run<T: Sendable>(timeout: TimeInterval, timeoutError: @escaping @Sendable () -> Error,
                                        _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await wait(Task { try await operation() }, timeout: timeout, timeoutError: timeoutError)
    }
}

/// Permiso de cámara de las gafas (lo concede Meta AI con un deeplink de ida y
/// vuelta). Si la app vuelve de Meta AI sin respuesta, se RE-CHEQUEA y se
/// sigue o se falla con un error claro: nunca se cuelga esperando. `onPrompt`
/// avisa justo antes de abrir Meta AI (el HUD pide aprobarlo y volver).
public enum GlassesCameraPermission {
    public static let noResponse = "Meta AI no respondió"
    public static let denied = "denegado"

    public static func ensure(check: @escaping @Sendable () async throws -> Bool,
                              request: @escaping @Sendable () async throws -> Bool,
                              timeout: TimeInterval = 90,
                              onPrompt: @escaping @Sendable () -> Void = {},
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        if try await check() { return }
        log("permiso de cámara: pidiendo a Meta AI")
        onPrompt()
        let why: String
        do {
            let granted = try await GlassesDeadline.run(
                timeout: timeout, timeoutError: { GlassesPhotoError.permissionDenied(noResponse) }, request)
            if granted { log("permiso de cámara: concedido"); return }
            why = denied
        } catch is CancellationError {
            throw CancellationError()
        } catch GlassesPhotoError.permissionDenied(let reason) {
            why = reason ?? denied
        } catch {
            why = "\(error)"
        }
        if (try? await check()) == true { log("permiso de cámara: concedido al volver"); return }
        log("permiso de cámara: \(why)")
        throw GlassesPhotoError.permissionDenied(why)
    }
}

/// Valor compartido con lock (callbacks de audio/SDK → la tarea que espera).
public final class GlassesBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    public init(_ value: T) { stored = value }
    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
