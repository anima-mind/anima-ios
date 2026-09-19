// PhoneContextTool.swift — tool `phone_context` (§5.7): última ubicación
// (CoreLocation), búsqueda de contactos (Contacts) y resumen de salud (HealthKit,
// read-only, agregado). Todo aferente → allow tras el permiso iOS. HealthKit va
// tras #if os(iOS) (no se compila fácil multiplataforma). Degrada elegante sin
// permiso (§8).

import Foundation

public struct PhoneContextTool: SensorimotorTool {
    public init() {}

    public var spec: ToolSpec {
        .client(
            name: "phone_context",
            description: """
                Contexto del teléfono del dueño (solo lectura). Acciones: location \
                (última ubicación conocida), contacts (busca un contacto por nombre), \
                health (resumen agregado: pasos, sueño, workouts de los últimos N días). \
                Nunca modifica nada.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("location"), .string("contacts"), .string("health")]),
                        "description": .string("Qué contexto consultar."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Nombre a buscar (para contacts)."),
                    ]),
                    "days": .object([
                        "type": .string("integer"),
                        "description": .string("Ventana en días (para health, default 7)."),
                    ]),
                ]),
                "required": .array([.string("action")]),
                "additionalProperties": .bool(false),
            ]))
    }

    // Todo aferente: percibe, nunca actúa.
    public func kind(for input: JSONValue) -> ToolKind { .afferent }
    public func operation(for input: JSONValue) -> String {
        input["action"]?.stringValue ?? "default"
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let action = input["action"]?.stringValue else {
            return ToolResult(content: "Error: falta 'action'.", isError: true)
        }
        switch action {
        case "location":
            return PhoneContextBackend.location()
        case "contacts":
            return await PhoneContextBackend.contacts(name: input["name"]?.stringValue)
        case "health":
            let days = { if case .int(let n) = input["days"] { return n } else { return 7 } }()
            return await PhoneContextBackend.health(days: days)
        default:
            return ToolResult(content: "Acción de contexto desconocida: \(action)", isError: true)
        }
    }
}

enum PhoneContextBackend {

    // MARK: - Location

    static func location() -> ToolResult {
        #if canImport(CoreLocation)
        return CoreLocationReader.lastKnown()
        #else
        return ToolResult(content: "La ubicación no está disponible en esta plataforma.", isError: true)
        #endif
    }

    // MARK: - Contacts

    static func contacts(name: String?) async -> ToolResult {
        guard let name, !name.isEmpty else {
            return ToolResult(content: "Error: falta 'name' para buscar contactos.", isError: true)
        }
        #if canImport(Contacts)
        return await ContactsReader.search(name: name)
        #else
        return ToolResult(content: "Los contactos no están disponibles en esta plataforma.", isError: true)
        #endif
    }

    // MARK: - Health

    static func health(days: Int) async -> ToolResult {
        #if os(iOS) && canImport(HealthKit)
        return await HealthReader.summary(days: max(1, days))
        #else
        // HealthKit no se compila fácil fuera de iOS: stub honesto (§5.7).
        return ToolResult(content: "El resumen de salud solo está disponible en el iPhone (pendiente de verificación en dispositivo).")
        #endif
    }
}

#if canImport(CoreLocation)
import CoreLocation

enum CoreLocationReader {
    static func lastKnown() -> ToolResult {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return ToolResult(content: "El dueño no ha concedido acceso a la ubicación.", isError: true)
        default:
            break
        }
        guard let location = manager.location else {
            return ToolResult(content: "No hay una ubicación reciente disponible.")
        }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        return ToolResult(content: String(format: "Última ubicación conocida: %.5f, %.5f (±%.0fm).",
                                           lat, lon, location.horizontalAccuracy))
    }
}
#endif

#if canImport(Contacts)
import Contacts

enum ContactsReader {
    static func search(name: String) async -> ToolResult {
        let store = CNContactStore()
        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { ok, _ in continuation.resume(returning: ok) }
        }
        guard granted else {
            return ToolResult(content: "El dueño no ha concedido acceso a contactos.", isError: true)
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            guard !contacts.isEmpty else {
                return ToolResult(content: "No se encontraron contactos que coincidan con '\(name)'.")
            }
            let lines = contacts.prefix(20).map { contact -> String in
                let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                let phones = contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
                return phones.isEmpty ? "- \(full)" : "- \(full): \(phones)"
            }
            return ToolResult(content: lines.joined(separator: "\n"))
        } catch {
            return ToolResult(content: "Error al buscar contactos: \(error.localizedDescription)", isError: true)
        }
    }
}
#endif

#if os(iOS) && canImport(HealthKit)
import HealthKit

enum HealthReader {
    static func summary(days: Int) async -> ToolResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            return ToolResult(content: "HealthKit no está disponible en este dispositivo.", isError: true)
        }
        // Fase 1: contrato + disponibilidad. Los summaries agregados (pasos, sueño,
        // workouts) se cablean con las HKQuery en la verificación en dispositivo.
        return ToolResult(content: "Resumen de salud disponible (últimos \(days) días); lectura agregada pendiente de verificación en dispositivo.")
    }
}
#endif
