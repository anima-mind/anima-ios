// AnimaWidgets.swift — la extensión WidgetKit. Lee SOLO el snapshot JSON del
// App Group (nunca GRDB): sin locks con la app. Hoy, Meta (configurable),
// pantalla de bloqueo, el control "Hablar con Anima" y la Live Activity del sueño.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import AnimaKit

@main
struct AnimaWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        GoalWidget()
        LockScreenWidget()
        TalkControl()
        SleepLiveActivity()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var goalId: String?

    var day: WidgetDay { snapshot.day(at: date) }
}

enum SnapshotSource {
    static func current(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshotStore.shared()?.read() ?? .placeholder(now: now)
    }

    static func entries(goalId: String? = nil) -> [SnapshotEntry] {
        let now = Date()
        let snapshot = current(now: now)
        return WidgetTimeline.entryDates(for: snapshot, from: now)
            .map { SnapshotEntry(date: $0, snapshot: snapshot, goalId: goalId) }
    }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date()
        let snapshot = context.isPreview ? WidgetSnapshot.sample(now: now) : SnapshotSource.current(now: now)
        completion(SnapshotEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: SnapshotSource.entries(), policy: .atEnd))
    }
}

struct GoalProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample(), goalId: "sample-goal")
    }

    func snapshot(for configuration: SelectGoalIntent, in context: Context) async -> SnapshotEntry {
        let now = Date()
        if context.isPreview { return SnapshotEntry(date: now, snapshot: .sample(now: now), goalId: "sample-goal") }
        return SnapshotEntry(date: now, snapshot: SnapshotSource.current(now: now), goalId: configuration.goal?.id)
    }

    func timeline(for configuration: SelectGoalIntent, in context: Context) async -> Timeline<SnapshotEntry> {
        Timeline(entries: SnapshotSource.entries(goalId: configuration.goal?.id), policy: .atEnd)
    }
}

// MARK: - Widgets

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mind.anima.today", provider: SnapshotProvider()) { entry in
            TodayEntryView(entry: entry)
        }
        .configurationDisplayName("Hoy")
        .description("Tu próximo recordatorio y el seguimiento de hoy.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium: TodayMediumView(day: entry.day, copy: WidgetCopy())
            default: TodaySmallView(day: entry.day, copy: WidgetCopy())
            }
        }
        .animaWidgetBackground()
    }
}

struct GoalWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "mind.anima.goal", intent: SelectGoalIntent.self, provider: GoalProvider()) { entry in
            let day = entry.day
            GoalSmallView(day: day, goal: day.goal(id: entry.goalId), copy: WidgetCopy())
                .animaWidgetBackground()
        }
        .configurationDisplayName("Meta")
        .description("Una meta con su racha y el próximo seguimiento.")
        .supportedFamilies([.systemSmall])
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mind.anima.lock", provider: SnapshotProvider()) { entry in
            LockEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Anima")
        .description("Lo próximo que te recordará, o su marca con tu racha.")
        .supportedFamilies([.accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

struct LockEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryInline: LockInlineView(day: entry.day, copy: WidgetCopy())
        case .accessoryCircular: LockCircularView(day: entry.day)
        default: LockRectangularView(day: entry.day, copy: WidgetCopy())
        }
    }
}

// MARK: - Centro de control / botón de Acción

struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "mind.anima.talk") {
            ControlWidgetButton(action: TalkToAnimaIntent()) {
                Label(WidgetCopy.talk, systemImage: "waveform")
            }
        }
        .displayName("Hablar con Anima")
        .description("Abre el chat con el micrófono escuchando.")
    }
}

// MARK: - Live Activity del sueño

struct SleepLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepActivityAttributes.self) { context in
            SleepActivityView(selfName: context.attributes.selfName, state: context.state)
                .activityBackgroundTint(Theme.Colors.bg)
                .activitySystemActionForegroundColor(Theme.Colors.accentText)
                .widgetURL(AnimaDeepLink.chat(turn: nil).url)
        } dynamicIsland: { context in
            let view = SleepActivityView(selfName: context.attributes.selfName, state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BreathMark(size: 36, p: 0.6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(view.title)
                        .font(Theme.Type_.cardTitle)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(view.subtitle)
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
            } compactLeading: {
                BreathMark(size: 22, p: 0.6)
            } compactTrailing: {
                Text(context.state.phase == .done ? "#\(context.state.night)" : "…")
                    .font(Theme.Type_.tabular(Theme.Type_.secondary))
                    .foregroundStyle(Theme.Colors.accentText)
            } minimal: {
                BreathMark(size: 20, p: 0.6)
            }
            .widgetURL(AnimaDeepLink.chat(turn: nil).url)
        }
    }
}
