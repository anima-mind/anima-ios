// SleepWindowSettingsSection.swift — "Hora de dormir" (Ajustes → Mente): desde
// y hasta en hora local. Las ruedas editan un borrador; el rango completo se
// valida y se guarda al tocar "Listo" (SleepWindowPreference) y re-encola el
// BGProcessingTask del sueño (lo cablea el shell).

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class SleepWindowSettingsModel: ObservableObject {
    public static let title = "Hora de dormir"
    public static let explanation =
        "Anima consolida tus memorias mientras el teléfono carga en este rango. iOS decide el momento exacto."
    public static let invalidNotice = "El rango debe durar entre 1 y 12 horas"

    public enum Field: String, Sendable {
        case start
        case end
    }

    /// El último rango válido guardado.
    @Published public private(set) var window: SleepWindow
    /// Lo que el dueño está eligiendo en las ruedas (sin validar ni guardar).
    @Published public private(set) var draftStart: SleepWindow.Time
    @Published public private(set) var draftEnd: SleepWindow.Time
    @Published public private(set) var editing: Field?
    @Published public private(set) var notice: String?
    /// Re-encola el sueño con la ventana nueva (lo cablea el shell).
    public var onChanged: (@Sendable (SleepWindow) async -> Void)?
    private let preference: SleepWindowPreference
    private let calendar: Calendar

    public init(preference: SleepWindowPreference, calendar: Calendar = .autoupdatingCurrent) {
        self.preference = preference
        self.calendar = calendar
        let window = preference.window
        self.window = window
        self.draftStart = window.start
        self.draftEnd = window.end
    }

    public var draft: SleepWindow { SleepWindow(start: draftStart, end: draftEnd) }

    public func draftTime(_ field: Field) -> SleepWindow.Time {
        field == .start ? draftStart : draftEnd
    }

    /// Abre la rueda de un extremo. Pasar al otro conserva el borrador.
    public func edit(_ field: Field) {
        editing = field
    }

    public func setDraft(_ field: Field, _ time: SleepWindow.Time) {
        switch field {
        case .start: draftStart = time
        case .end: draftEnd = time
        }
    }

    /// "Listo": valida el rango completo. Válido → guarda, re-encola y cierra
    /// la rueda; inválido → aviso, la rueda sigue abierta con lo elegido y se
    /// conserva el último rango guardado.
    @discardableResult
    public func commit() async -> Bool {
        let candidate = draft
        guard candidate != window else {
            notice = nil
            editing = nil
            return true
        }
        guard preference.set(candidate) else {
            notice = Self.invalidNotice
            return false
        }
        window = candidate
        notice = nil
        editing = nil
        await onChanged?(candidate)
        return true
    }

    /// Al salir de la pantalla sin un rango válido: vuelve a lo guardado.
    public func discardDraft() {
        draftStart = window.start
        draftEnd = window.end
        editing = nil
        notice = nil
    }

    public func refresh() {
        window = preference.window
        if editing == nil {
            draftStart = window.start
            draftEnd = window.end
        }
    }

    public func date(for time: SleepWindow.Time, reference: Date = Date()) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: reference) ?? reference
    }

    public func time(from date: Date) -> SleepWindow.Time {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return SleepWindow.Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}

struct SleepWindowSettingsSection: View {
    @ObservedObject var model: SleepWindowSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text(SleepWindowSettingsModel.title)
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
                .accessibilityIdentifier("settings.sleepWindow")
            VStack(spacing: 0) {
                row("Desde", .start)
                Divider().background(Theme.Colors.border)
                row("Hasta", .end)
                if let field = model.editing {
                    Divider().background(Theme.Colors.border)
                    editor(field)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            if let notice = model.notice {
                Text(notice)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.accentText)
                    .accessibilityIdentifier("settings.sleepWindow.notice")
            }
            Text(SleepWindowSettingsModel.explanation)
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .onAppear { model.refresh() }
        .onDisappear {
            Task {
                if !(await model.commit()) { model.discardDraft() }
            }
        }
    }

    private func row(_ title: String, _ field: SleepWindowSettingsModel.Field) -> some View {
        let value = model.date(for: model.draftTime(field)).formatted(date: .omitted, time: .shortened)
        let selected = model.editing == field
        return Button {
            model.edit(field)
        } label: {
            HStack {
                Text(title)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                Text(value)
                    .font(Theme.Type_.body)
                    .foregroundStyle(selected ? Theme.Colors.accentText : Theme.Colors.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(selected ? Theme.Colors.tint : Theme.Colors.surface))
            }
            .frame(minHeight: 48)
            .padding(.horizontal, Theme.Space.cardPad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("settings.sleepWindow.\(field.rawValue)")
    }

    private func editor(_ field: SleepWindowSettingsModel.Field) -> some View {
        VStack(spacing: 0) {
            DatePicker(field == .start ? "Desde" : "Hasta",
                       selection: Binding(get: { model.date(for: model.draftTime(field)) },
                                          set: { model.setDraft(field, model.time(from: $0)) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .wheelDatePickerStyle()
                .id(field)
                .accessibilityIdentifier("settings.sleepWindow.picker")
            Button {
                Task { await model.commit() }
            } label: {
                Text("Listo")
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.sleepWindow.done")
        }
        .padding(.horizontal, Theme.Space.cardPad)
        .padding(.bottom, Theme.Space.unit * 2)
    }
}

private extension View {
    func wheelDatePickerStyle() -> some View {
        #if os(iOS)
        self.datePickerStyle(.wheel)
        #else
        self
        #endif
    }
}
#endif
