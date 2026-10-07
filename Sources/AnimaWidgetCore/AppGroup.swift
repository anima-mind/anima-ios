// AppGroup.swift — el contenedor compartido entre la app y la extensión de
// widgets. UNA sola constante: project.yml, los .entitlements y este código
// deben decir exactamente lo mismo (registrado en Apple por el dueño).

import Foundation

public enum AppGroup {
    public static let identifier = "group.com.joshuamoreno1.anima.widgets"

    /// Raíz del contenedor del grupo. nil si el binario no trae el entitlement
    /// (build sin firma, tests del package): quien llama cae a su sandbox.
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// `<grupo>/Database`: la base única de Anima (y sus sidecars).
    public static func databaseDirectory(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?.appendingPathComponent("Database", isDirectory: true)
    }

    /// `<grupo>/Widgets`: snapshot que lee la extensión + cola de acciones.
    public static func widgetsDirectory(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?.appendingPathComponent("Widgets", isDirectory: true)
    }
}
