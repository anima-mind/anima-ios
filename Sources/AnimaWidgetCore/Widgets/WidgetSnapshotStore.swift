// WidgetSnapshotStore.swift — el snapshot en disco: la app lo escribe y la
// extensión lo lee.

import Foundation

/// El JSON en `<grupo>/Widgets/WidgetSnapshot.json`: escritura atómica (la
/// extensión nunca ve un archivo a medias) y lectura tolerante.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "WidgetSnapshot.json"

    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    /// `<grupo>/Widgets` o nil sin App Group.
    public static func shared() -> WidgetSnapshotStore? {
        AppGroup.widgetsDirectory().map(WidgetSnapshotStore.init(directory:))
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        // Los widgets de bloqueo leen con el teléfono bloqueado (tras el primer desbloqueo).
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try encoder.encode(snapshot).write(to: url, options: options)
    }

    /// nil si no existe, está corrupto o es de una versión futura.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version <= WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
