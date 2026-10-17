// SleepWindowSettingsSection.swift — "Hora de dormir" (Ajustes → Mente): desde
// y hasta en hora local, persistidos en SleepWindowPreference. Cambiar el rango
// re-encola el BGProcessingTask del sueño (lo cablea el shell).

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class SleepWindowSettingsModel: ObservableObject {
    public static let title = "Hora de dormir"
    public static let explanation =
        "Anima consolida tus memorias mientras el teléfono carga en este rango. iOS decide el momento exacto."
    public static let invalidNotice = "El rango debe durar entre 1 y 12 horas."

    @Published public private(set) var window: SleepWindow
    @Published public private(set) var notice: String?
    /// Sube al rechazar un rango: los selectores se redibujan con lo guardado.
    @Published public private(set) var revision = 0
    /// Re-encola el sueño con la ventana nueva (lo cablea el shell).
    public var onChanged: (@Sendable (SleepWindow) async -> Void)?
    private let preference: SleepWindowPreference
    private let calendar: Calendar

    public init(preference: SleepWindowPreference, calendar: Calendar = .autoupdatingCurrent) {
        self.preference = preference
        self.calendar = calendar
        self.window = preference.window
    }

    @discardableResult
    public func setStart(_ time: SleepWindow.Time) async -> Bool {
        await apply(SleepWindow(start: time, end: window.end))
    }

    @discardableResult
    public func setEnd(_ time: SleepWindow.Time) async -> Bool {
        await apply(SleepWindow(start: window.start, end: time))
    }

    /// Persiste y re-encola; fuera de 1–12 h no cambia nada y avisa.
    @discardableResult
    public func apply(_ candidate: SleepWindow) async -> Bool {
        guard candidate != window else {
            notice = nil
            return true
        }
        guard preference.set(candidate) else {
            notice = Self.invalidNotice
            revision += 1
            return false
        }
        window = candidate
        notice = nil
        await onChanged?(candidate)
        return true
    }

    public func refresh() {
        window = preference.window
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
                row("Desde", id: "settings.sleepWindow.start", time: model.window.start) { time in
                    Task { await model.setStart(time) }
                }
                Divider().background(Theme.Colors.border)
                row("Hasta", id: "settings.sleepWindow.end", time: model.window.end) { time in
                    Task { await model.setEnd(time) }
                }
            }
            .id(model.revision)
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
    }

    private func row(_ title: String, id: String, time: SleepWindow.Time,
                     set: @escaping (SleepWindow.Time) -> Void) -> some View {
        HStack {
            Text(title)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
            Spacer()
            DatePicker(title, selection: Binding(get: { model.date(for: time) },
                                                 set: { set(model.time(from: $0)) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .compactDatePickerStyle()
                .accessibilityIdentifier(id)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, Theme.Space.cardPad)
    }
}

private extension View {
    func compactDatePickerStyle() -> some View {
        #if os(iOS)
        self.datePickerStyle(.compact)
        #else
        self
        #endif
    }
}
#endif
