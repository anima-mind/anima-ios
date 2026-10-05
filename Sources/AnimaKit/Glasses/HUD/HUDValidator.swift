// HUDValidator.swift — el checklist del doc 06 §6 como código. Todo árbol que va
// a las gafas pasa por aquí (los del renderer en tests; los del agente vía
// `glasses_show` en runtime). Más el parser JSON → HUDView para la tool: lo que
// no está en el vocabulario cerrado se RECHAZA con un error legible, jamás se
// "aproxima".

import Foundation

/// Acciones estándar del HUD (IDs estables que el renderer y el adapter comparten).
public extension HUDActionID {
    static let back: HUDActionID = "back"
    static let talk: HUDActionID = "talk"
    static let photo: HUDActionID = "photo"
    static let cancel: HUDActionID = "cancel"
    static let send: HUDActionID = "send"
    static let again: HUDActionID = "again"
    static let reply: HUDActionID = "reply"
    static let onPhone: HUDActionID = "on_phone"
    static let dismiss: HUDActionID = "dismiss"
    static let cameraAllow: HUDActionID = "camera_allow"
    static let cameraDeny: HUDActionID = "camera_deny"
}

public enum HUDValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooManyButtons(Int)
    case tooManyInteractive(Int)
    case missingBack
    case textTooLong(style: HUDTextStyle, count: Int, limit: Int)
    case emptyText
    case emptyButtonGroup
    case invalidImageURI(String)
    case tooDeep(Int)
    case invalidNumber(String)
    case unknownComponent(String)
    case unknownValue(field: String, value: String)
    case missingField(String)
    case notAnObject(String)
    case rootNotFlexBox

    public var description: String {
        switch self {
        case .tooManyButtons(let n): return "demasiados botones (\(n); máximo 3 por vista)"
        case .tooManyInteractive(let n): return "demasiados elementos interactivos (\(n); máximo 4)"
        case .missingBack: return "toda vista no-raíz necesita un botón Atrás (action back)"
        case .textTooLong(let style, let count, let limit):
            return "texto \(style.rawValue) de \(count) caracteres (máximo \(limit)); el resto va al teléfono"
        case .emptyText: return "texto vacío"
        case .emptyButtonGroup: return "button_group sin botones"
        case .invalidImageURI(let uri): return "uri de imagen inválida: \(uri)"
        case .tooDeep(let depth): return "árbol demasiado profundo (\(depth) niveles; máximo 5)"
        case .invalidNumber(let field): return "número inválido en \(field) (0…64)"
        case .unknownComponent(let type):
            return "componente '\(type)' no existe en el HUD (solo flexbox, text, icon, image, button, button_group)"
        case .unknownValue(let field, let value): return "valor '\(value)' no válido para \(field)"
        case .missingField(let field): return "falta el campo \(field)"
        case .notAnObject(let field): return "\(field) debe ser un objeto"
        case .rootNotFlexBox: return "el root de la vista debe ser un flexbox"
        }
    }
}

public enum HUDValidator {
    /// Presupuesto por vista (doc 06 §5.2, hud-projection): no es límite del SDK,
    /// es respeto por una pantalla en la cara.
    public static let headingLimit = 40
    public static let bodyLimit = 200
    public static let metaLimit = 60
    public static let maxButtons = 3
    public static let maxInteractive = 4
    public static let maxDepth = 5

    /// Valida una vista completa contra el checklist. Devuelve el primer error.
    public static func validate(_ view: HUDView) throws(HUDValidationError) {
        let buttons = view.buttons.count
        if buttons > maxButtons { throw .tooManyButtons(buttons) }
        let interactive = view.actions.count
        if interactive > maxInteractive { throw .tooManyInteractive(interactive) }
        if !view.isRoot, !view.actions.contains(.back) { throw .missingBack }
        try validate(.flexBox(view.root), depth: 1)
    }

    public static func isValid(_ view: HUDView) -> Bool {
        do { try validate(view); return true } catch { return false }
    }

    private static func validate(_ node: HUDNode, depth: Int) throws(HUDValidationError) {
        if depth > maxDepth { throw .tooDeep(depth) }
        switch node {
        case .flexBox(let box):
            try checkNumber(box.spacing, "spacing")
            if let padding = box.padding { try checkNumber(padding, "padding") }
            for child in box.children { try validate(child, depth: depth + 1) }
        case .text(let text):
            let trimmed = text.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw .emptyText }
            let limit = limit(for: text.style)
            if text.content.count > limit { throw .textTooLong(style: text.style, count: text.content.count, limit: limit) }
        case .button(let button):
            if button.label.trimmingCharacters(in: .whitespaces).isEmpty { throw .emptyText }
            if button.label.count > metaLimit {
                throw .textTooLong(style: .meta, count: button.label.count, limit: metaLimit)
            }
        case .buttonGroup(let group):
            if group.buttons.isEmpty { throw .emptyButtonGroup }
            for button in group.buttons { try validate(.button(button), depth: depth + 1) }
        case .image(let image):
            guard let url = URL(string: image.uri), let scheme = url.scheme?.lowercased(),
                  ["https", "file"].contains(scheme) else { throw .invalidImageURI(image.uri) }
        case .icon:
            break   // el tipo HUDIcon ya garantiza el catálogo cerrado
        }
    }

    static func limit(for style: HUDTextStyle) -> Int {
        switch style {
        case .heading: return headingLimit
        case .body: return bodyLimit
        case .meta: return metaLimit
        }
    }

    private static func checkNumber(_ value: Double, _ field: String) throws(HUDValidationError) {
        guard value.isFinite, value >= 0, value <= 64 else { throw .invalidNumber(field) }
    }
}

// MARK: - JSON → HUDView (input de `glasses_show`)

/// Parser estricto del árbol que manda el agente. Formato (snake_case):
///   {"type":"flexbox","direction":"column","spacing":12,"padding":16,"background":"card",
///    "children":[{"type":"text","content":"…","style":"heading","color":"primary"},
///                {"type":"icon","name":"bell","style":"outline"},
///                {"type":"image","uri":"https://…","size":"icon","corner_radius":"small"},
///                {"type":"button_group","alignment":"end","buttons":[
///                    {"type":"button","label":"Listo","style":"primary","icon":"checkmark","action":"dismiss"}]}]}
/// Las acciones que el agente puede cablear son un set cerrado: dismiss / on_phone / talk.
public enum HUDTreeParser {
    public static let agentActions: Set<HUDActionID> = [.dismiss, .onPhone, .talk]

    public static func parseRoot(_ json: JSONValue) throws(HUDValidationError) -> HUDFlexBox {
        guard case .object = json else { throw .notAnObject("tree") }
        guard case .flexBox(let box) = try parse(json, depth: 1) else { throw .rootNotFlexBox }
        return box
    }

    static func parse(_ json: JSONValue, depth: Int) throws(HUDValidationError) -> HUDNode {
        if depth > HUDValidator.maxDepth { throw .tooDeep(depth) }
        guard case .object(let obj) = json else { throw .notAnObject("nodo") }
        guard let type = obj["type"]?.stringValue else { throw .missingField("type") }
        switch type {
        case "flexbox":
            var children: [HUDNode] = []
            if let raw = obj["children"] {
                guard case .array(let items) = raw else { throw .notAnObject("children") }
                for item in items { children.append(try parse(item, depth: depth + 1)) }
            }
            return .flexBox(HUDFlexBox(
                direction: try enumValue(obj, "direction", default: .column),
                spacing: try number(obj, "spacing") ?? 0,
                alignment: try enumValue(obj, "alignment", default: .start),
                crossAlignment: try enumValue(obj, "cross_alignment", default: .start),
                padding: try number(obj, "padding"),
                background: try enumValue(obj, "background", default: .none),
                onTap: try action(obj, "on_tap"),
                children: children))
        case "text":
            guard let content = obj["content"]?.stringValue else { throw .missingField("content") }
            return .text(HUDText(content, style: try enumValue(obj, "style", default: .body),
                                 color: try enumValue(obj, "color", default: .primary)))
        case "icon":
            guard let name = obj["name"]?.stringValue else { throw .missingField("name") }
            guard let icon = HUDIcon(rawValue: name) else { throw .unknownValue(field: "icon", value: name) }
            return .icon(HUDIconNode(icon, style: try enumValue(obj, "style", default: .outline)))
        case "image":
            guard let uri = obj["uri"]?.stringValue else { throw .missingField("uri") }
            return .image(HUDImage(uri: uri, size: try enumValue(obj, "size", default: .icon),
                                   cornerRadius: try enumValue(obj, "corner_radius", default: .none)))
        case "button":
            return .button(try button(obj))
        case "button_group":
            guard case .array(let items)? = obj["buttons"] else { throw .missingField("buttons") }
            var buttons: [HUDButton] = []
            for item in items {
                guard case .object(let b) = item else { throw .notAnObject("button") }
                if let t = b["type"]?.stringValue, t != "button" { throw .unknownComponent(t) }
                buttons.append(try button(b))
            }
            return .buttonGroup(HUDButtonGroup(alignment: try enumValue(obj, "alignment", default: .center),
                                               buttons: buttons))
        default:
            throw .unknownComponent(type)
        }
    }

    private static func button(_ obj: [String: JSONValue]) throws(HUDValidationError) -> HUDButton {
        guard let label = obj["label"]?.stringValue else { throw .missingField("label") }
        var icon: HUDIcon?
        if let name = obj["icon"]?.stringValue {
            guard let parsed = HUDIcon(rawValue: name) else { throw .unknownValue(field: "icon", value: name) }
            icon = parsed
        }
        guard let action = try action(obj, "action") else { throw .missingField("action") }
        return HUDButton(label, style: try enumValue(obj, "style", default: .primary), icon: icon, action: action)
    }

    private static func action(_ obj: [String: JSONValue], _ key: String) throws(HUDValidationError) -> HUDActionID? {
        guard let raw = obj[key]?.stringValue else { return nil }
        let id = HUDActionID(rawValue: raw)
        guard agentActions.contains(id) else { throw .unknownValue(field: key, value: raw) }
        return id
    }

    private static func number(_ obj: [String: JSONValue], _ key: String) throws(HUDValidationError) -> Double? {
        switch obj[key] {
        case nil, .null?: return nil
        case .int(let n)?: return Double(n)
        case .double(let d)?: return d
        default: throw .invalidNumber(key)
        }
    }

    private static func enumValue<E: RawRepresentable>(_ obj: [String: JSONValue], _ key: String,
                                                       default value: E) throws(HUDValidationError) -> E
    where E.RawValue == String {
        guard let raw = obj[key]?.stringValue else {
            if let present = obj[key], present != .null { throw .unknownValue(field: key, value: "\(present)") }
            return value
        }
        guard let parsed = E(rawValue: raw) else { throw .unknownValue(field: key, value: raw) }
        return parsed
    }
}
