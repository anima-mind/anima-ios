// PhoneContextTool.swift — tool `phone_context` (§5.7): última ubicación
// (CoreLocation), búsqueda de contactos (Contacts) y resumen de salud (HealthKit,
// read-only, agregado). Todo aferente → allow tras el permiso iOS. HealthKit va
// tras #if os(iOS) (no se compila fácil multiplataforma). Degrada elegante sin
// permiso (§8). Validación y formato son puros contra `PhoneContextSources`;
// los lectores de frameworks (CoreLocation/Contacts/HealthKit) van tras #if.

import Foundation

public struct PhoneContextTool: SensorimotorTool {
    private let sources: any PhoneContextSources

    public init() {
        self.init(sources: SystemPhoneContextSources())
    }

    /// Inyección para tests (los frameworks reales piden permiso iOS).
    init(sources: any PhoneContextSources) {
        self.sources = sources
    }

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
            return PhoneContextFormat.location(sources.lastLocation())
        case "contacts":
            guard let name = input["name"]?.stringValue, !name.isEmpty else {
                return ToolResult(content: "Error: falta 'name' para buscar contactos.", isError: true)
            }
            return PhoneContextFormat.contacts(await sources.searchContacts(name: name), name: name)
        case "health":
            let days = { if case .int(let n) = input["days"] { return n } else { return 7 } }()
            return await sources.healthSummary(days: max(1, days))
        default:
            return ToolResult(content: "Acción de contexto desconocida: \(action)", isError: true)
        }
    }
}

// MARK: - Fuentes (frontera con los frameworks)

enum LocationReading: Sendable, Equatable {
    case unavailable            // plataforma sin CoreLocation
    case denied                 // denied / restricted
    case noFix                  // permiso ok pero sin ubicación reciente
    case fix(latitude: Double, longitude: Double, accuracy: Double)
}

struct ContactRecord: Sendable, Equatable {
    var givenName: String
    var familyName: String
    var phones: [String]
}

enum ContactsLookup: Sendable, Equatable {
    case unavailable
    case denied
    case failed(String)
    case found([ContactRecord])
}

protocol PhoneContextSources: Sendable {
    func lastLocation() -> LocationReading
    func searchContacts(name: String) async -> ContactsLookup
    func healthSummary(days: Int) async -> ToolResult
}

// MARK: - Formato (puro)

enum PhoneContextFormat {
    static let maxContacts = 20

    static func location(_ reading: LocationReading) -> ToolResult {
        switch reading {
        case .unavailable:
            return ToolResult(content: "La ubicación no está disponible en esta plataforma.", isError: true)
        case .denied:
            return ToolResult(content: "El dueño no ha concedido acceso a la ubicación.", isError: true)
        case .noFix:
            return ToolResult(content: "No hay una ubicación reciente disponible.")
        case .fix(let lat, let lon, let accuracy):
            return ToolResult(content: String(format: "Última ubicación conocida: %.5f, %.5f (±%.0fm).",
                                               lat, lon, accuracy))
        }
    }

    static func contacts(_ lookup: ContactsLookup, name: String) -> ToolResult {
        switch lookup {
        case .unavailable:
            return ToolResult(content: "Los contactos no están disponibles en esta plataforma.", isError: true)
        case .denied:
            return ToolResult(content: "El dueño no ha concedido acceso a contactos.", isError: true)
        case .failed(let message):
            return ToolResult(content: "Error al buscar contactos: \(message)", isError: true)
        case .found(let contacts):
            guard !contacts.isEmpty else {
                return ToolResult(content: "No se encontraron contactos que coincidan con '\(name)'.")
            }
            let lines = contacts.prefix(maxContacts).map { contact -> String in
                let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                let phones = contact.phones.joined(separator: ", ")
                return phones.isEmpty ? "- \(full)" : "- \(full): \(phones)"
            }
            return ToolResult(content: lines.joined(separator: "\n"))
        }
    }
}

// MARK: - Fuentes reales

struct SystemPhoneContextSources: PhoneContextSources {
    func lastLocation() -> LocationReading {
        #if canImport(CoreLocation)
        return CoreLocationReader.lastKnown()
        #else
        return .unavailable
        #endif
    }

    func searchContacts(name: String) async -> ContactsLookup {
        #if canImport(Contacts)
        return await ContactsReader.search(name: name)
        #else
        return .unavailable
        #endif
    }

    func healthSummary(days: Int) async -> ToolResult {
        #if os(iOS) && canImport(HealthKit)
        return await HealthReader.summary(days: days)
        #else
        // HealthKit no se compila fácil fuera de iOS: stub honesto (§5.7).
        return ToolResult(content: "El resumen de salud solo está disponible en el iPhone (pendiente de verificación en dispositivo).")
        #endif
    }
}

#if canImport(CoreLocation)
import CoreLocation

enum CoreLocationReader {
    static func lastKnown() -> LocationReading {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return .denied
        default:
            break
        }
        guard let location = manager.location else { return .noFix }
        return .fix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                    accuracy: location.horizontalAccuracy)
    }
}
#endif

#if canImport(Contacts)
import Contacts

enum ContactsReader {
    static func search(name: String) async -> ContactsLookup {
        let store = CNContactStore()
        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { ok, _ in continuation.resume(returning: ok) }
        }
        guard granted else { return .denied }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            return .found(contacts.map {
                ContactRecord(givenName: $0.givenName, familyName: $0.familyName,
                              phones: $0.phoneNumbers.map { $0.value.stringValue })
            })
        } catch {
            return .failed(error.localizedDescription)
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
