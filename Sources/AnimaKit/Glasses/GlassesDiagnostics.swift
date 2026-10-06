// GlassesDiagnostics.swift — bitácora de campo de las gafas: los
// últimos N eventos del cuerpo (link/compat/sesión/display/fallos), de la ruta
// de audio (settle HFP ms y resultado, formato del input) y de la foto (estados
// con timestamp, errores mapeados). Sin hardware en CI, esto es lo que el dueño
// copia desde Ajustes → Gafas → Diagnóstico cuando algo falla en las gafas.
// Thread-safe (listeners del SDK llegan en cualquier hilo). Sin PII: solo estados.

import Foundation

public final class GlassesDiagnostics: @unchecked Sendable {
    public enum Category: String, Sendable, Equatable, CaseIterable {
        case registration, link, compat, session, display, fault, hud, icons, photo, audio, error
    }

    public struct Entry: Sendable, Equatable {
        public var date: Date
        public var category: Category
        public var message: String
        public init(date: Date, category: Category, message: String) {
            self.date = date
            self.category = category
            self.message = message
        }
    }

    /// La instancia de la app (el adapter DAT no recibe inyección).
    public static let shared = GlassesDiagnostics()

    public let capacity: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var observers: [UUID: AsyncStream<[Entry]>.Continuation] = [:]

    public init(capacity: Int = 30, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    public func record(_ category: Category, _ message: String) {
        let entry = Entry(date: now(), category: category, message: message)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let snapshot = buffer
        let targets = Array(observers.values)
        lock.unlock()
        for target in targets { target.yield(snapshot) }
    }

    public var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return buffer }

    public func clear() {
        lock.lock()
        buffer = []
        let targets = Array(observers.values)
        lock.unlock()
        for target in targets { target.yield([]) }
    }

    /// Emite lo actual y cada cambio.
    public func updates() -> AsyncStream<[Entry]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Entry]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock()
        observers[id] = continuation
        let snapshot = buffer
        lock.unlock()
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    /// Una línea por evento: `HH:mm:ss.SSS [categoría] mensaje`.
    public static func line(_ entry: Entry) -> String {
        "\(timestamp(entry.date)) [\(entry.category.rawValue)] \(entry.message)"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// "1 evento" / "3 eventos".
    public static func eventCount(_ count: Int) -> String {
        count == 1 ? "1 evento" : "\(count) eventos"
    }

    /// Las líneas en el orden en que se muestran y se copian: el más reciente
    /// primero (en pantalla queda visible sin hacer scroll).
    var newestFirstLines: [String] { entries.reversed().map(Self.line) }

    /// El texto que se copia al portapapeles: cabecera de estado + eventos.
    public func report(header: [String]) -> String {
        let lines = newestFirstLines
        let title = lines.count == 1 ? "— último evento —"
                                     : "— últimos \(Self.eventCount(lines.count)), el más reciente primero —"
        return (["Anima · diagnóstico de gafas"] + header + [title]
                + (lines.isEmpty ? ["(sin eventos)"] : lines)).joined(separator: "\n")
    }
}
