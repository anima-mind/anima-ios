// WidgetViews.swift — las vistas de los widgets (compartidas app ↔ extensión:
// la extensión las pinta en WidgetKit y la app en la galería de `--uitest`).
// Sistema de diseño de Anima: dark-first, un solo acento siempre línea o glow
// (nunca fill), sin rojo ni verde, la marca BreathMark estática. Todo en español.

import SwiftUI
import WidgetKit
import AnimaKit

// MARK: - Piezas

/// Marca + nombre del self (encabezado de los widgets de pantalla de inicio).
struct WidgetHeader: View {
    let day: WidgetDay
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            BreathMark(size: 28, p: day.plasticity)
            Text(day.selfName)
                .font(Theme.Type_.label)
                .kerning(0.66)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.textMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
                    .lineLimit(1)
            }
        }
    }
}

/// Botón del widget: contorno de acento, nunca relleno.
struct WidgetActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Type_.meta.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.Colors.accentText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().stroke(Theme.Colors.accent.opacity(0.7), lineWidth: Theme.Stroke.hairline))
            .contentShape(Capsule())
    }
}

struct EmptyToday: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WidgetCopy.emptyToday)
                .font(compact ? Theme.Type_.body.weight(.medium) : Theme.Type_.cardTitle)
                .foregroundStyle(Theme.Colors.text)
            Text(WidgetCopy.emptyHint)
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Fondo del sistema de diseño (contenedor de WidgetKit).
    func animaWidgetBackground() -> some View {
        containerBackground(for: .widget) {
            ZStack {
                Theme.Colors.bg
                RadialGradient(colors: [Theme.Colors.groundInner.opacity(0.9), Theme.Colors.bg.opacity(0)],
                               center: UnitPoint(x: 0.2, y: 0.0), startRadius: 0, endRadius: 220)
            }
        }
    }
}

// MARK: - Hoy (small / medium)

struct TodaySmallView: View {
    let day: WidgetDay
    let copy: WidgetCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(day: day)
            Spacer(minLength: 0)
            if let next = day.next {
                Text(WidgetCopy.nextLabel)
                    .font(Theme.Type_.label).kerning(0.66).textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.textFaint)
                Text(next.text)
                    .font(Theme.Type_.cardTitle)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(copy.relative(next.at, now: day.now))
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .lineLimit(1)
            } else if day.reminders.isEmpty, day.pendingCheckIn == nil {
                EmptyToday(compact: true)
            }
            if let checkIn = day.pendingCheckIn {
                Text("\(WidgetCopy.followUp) · \(copy.clock(checkIn.at))")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .lineLimit(1)
                if day.next == nil {
                    Text(checkIn.statement)
                        .font(Theme.Type_.cardTitle)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(day.next != nil ? AnimaDeepLink.reminders.url
                   : day.pendingCheckIn.map { AnimaDeepLink.goals(id: $0.goalId).url } ?? AnimaDeepLink.chat(turn: nil).url)
    }
}

struct TodayMediumView: View {
    let day: WidgetDay
    let copy: WidgetCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: AnimaDeepLink.chat(turn: nil).url) {
                WidgetHeader(day: day, trailing: copy.nights(day.nights))
            }
            if day.isEmpty, day.next == nil {
                Spacer(minLength: 0)
                EmptyToday()
                Spacer(minLength: 0)
            } else {
                reminderRow
                checkInRow
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// El recordatorio que importa: el de hoy vencido sin cerrar, o el próximo.
    private var reminder: WidgetDay.ReminderLine? {
        day.reminders.first { $0.overdue } ?? day.next
    }

    @ViewBuilder private var reminderRow: some View {
        if let reminder {
            HStack(alignment: .center, spacing: 8) {
                Link(destination: AnimaDeepLink.reminders.url) {
                    HStack(spacing: 8) {
                        Image(systemName: "bell")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reminder.text)
                                .font(Theme.Type_.body.weight(.medium))
                                .foregroundStyle(Theme.Colors.text)
                                .lineLimit(1)
                            Text(copy.relative(reminder.at, now: day.now))
                                .font(Theme.Type_.meta)
                                .foregroundStyle(Theme.Colors.accentText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                }
                Button(intent: CompleteReminderIntent(reminderId: reminder.id)) {
                    WidgetActionLabel(title: WidgetCopy.done, systemImage: "checkmark")
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "bell")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textFaint)
                    .frame(width: 18)
                Text("Sin recordatorios pendientes")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textFaint)
            }
        }
    }

    @ViewBuilder private var checkInRow: some View {
        if let checkIn = day.pendingCheckIn {
            HStack(alignment: .center, spacing: 8) {
                Link(destination: AnimaDeepLink.goals(id: checkIn.goalId).url) {
                    HStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(checkIn.statement)
                                .font(Theme.Type_.body.weight(.medium))
                                .foregroundStyle(Theme.Colors.text)
                                .lineLimit(1)
                            Text("\(WidgetCopy.followUp) · \(copy.dates.time(checkIn.at))")
                                .font(Theme.Type_.meta)
                                .foregroundStyle(Theme.Colors.textMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                }
                Button(intent: ProgressCheckInIntent(goalId: checkIn.goalId)) {
                    WidgetActionLabel(title: WidgetCopy.progressed, systemImage: "arrow.up.right")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Meta (small, configurable)

struct GoalSmallView: View {
    let day: WidgetDay
    let goal: WidgetDay.GoalLine?
    let copy: WidgetCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                BreathMark(size: 26, p: day.plasticity)
                Text("Meta")
                    .font(Theme.Type_.label).kerning(0.66).textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.textFaint)
                Spacer(minLength: 0)
            }
            if let goal {
                Text(goal.statement)
                    .font(Theme.Type_.cardTitle)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "flame")
                        .font(.system(size: 11))
                        .foregroundStyle(goal.streak > 0 ? Theme.Colors.accent : Theme.Colors.textFaint)
                    Text(copy.streak(goal.streak))
                        .font(Theme.Type_.tabular(Theme.Type_.secondary))
                        .foregroundStyle(goal.streak > 0 ? Theme.Colors.accentText : Theme.Colors.textMuted)
                        .lineLimit(1)
                }
                if day.checkIns.contains(where: { $0.goalId == goal.id && !$0.answered }) {
                    Button(intent: ProgressCheckInIntent(goalId: goal.id)) {
                        WidgetActionLabel(title: WidgetCopy.progressed, systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(goal.nextCheckIn.map { "Seguimiento \(copy.dates.moment($0, now: day.now))" } ?? "Sin seguimiento")
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .lineLimit(2)
                }
            } else {
                Spacer(minLength: 0)
                Text(WidgetCopy.noGoals)
                    .font(Theme.Type_.cardTitle)
                    .foregroundStyle(Theme.Colors.text)
                Text(WidgetCopy.noGoalsHint)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(AnimaDeepLink.goals(id: goal?.id).url)
    }
}

// MARK: - Pantalla de bloqueo

struct LockInlineView: View {
    let day: WidgetDay
    let copy: WidgetCopy

    var body: some View {
        Label(copy.lockLine(day), systemImage: day.next == nil ? "checkmark.circle" : "bell")
            .widgetURL(AnimaDeepLink.reminders.url)
    }
}

struct LockRectangularView: View {
    let day: WidgetDay
    let copy: WidgetCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let next = day.next {
                HStack(spacing: 4) {
                    Image(systemName: "bell")
                    Text("\(WidgetCopy.nextLabel) · \(nextTime(next.at))")
                }
                .font(.system(size: 12, weight: .medium))
                .widgetAccentable()
                Text(next.text)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text(day.selfName)
                }
                .font(.system(size: 12, weight: .medium))
                .widgetAccentable()
                Text(WidgetCopy.emptyToday)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(AnimaDeepLink.reminders.url)
    }

    private func nextTime(_ date: Date) -> String {
        copy.dates.calendar.isDate(date, inSameDayAs: day.now) ? copy.clock(date) : copy.dates.moment(date, now: day.now)
    }
}

/// Circular: la marca, y la mejor racha viva debajo si hay.
struct LockCircularView: View {
    let day: WidgetDay

    private var streak: Int { day.goals.map(\.streak).max() ?? 0 }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                BreathMark(size: streak > 0 ? 30 : 40, p: day.plasticity)
                    .widgetAccentable()
                if streak > 0 {
                    Text("\(streak)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
            }
        }
        .widgetURL(AnimaDeepLink.chat(turn: nil).url)
    }
}

// MARK: - Live Activity del sueño

struct SleepActivityView: View {
    let selfName: String
    let state: SleepActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            BreathMark(size: 44, p: 0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Type_.cardTitle)
                    .foregroundStyle(Theme.Colors.text)
                Text(subtitle)
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    var title: String {
        switch state.phase {
        case .consolidating: return WidgetCopy.consolidating(selfName)
        case .done: return WidgetCopy.nightReady(state.night)
        case .interrupted: return "La noche quedó a medias"
        }
    }

    var subtitle: String {
        switch state.phase {
        case .consolidating: return "Ordenando lo que vivieron hoy"
        case .done: return "Memorias y metas al día"
        case .interrupted: return "Retomará en el próximo descanso"
        }
    }
}
