// WidgetGallery.swift — SOLO `--uitest --uitest-widget-gallery`: pinta cada
// widget (las MISMAS vistas de la extensión, App/WidgetsShared) a su tamaño
// real de iPhone 6.3" con datos de ejemplo, para los screenshots del XCUITest.

import SwiftUI
import WidgetKit
import AnimaKit

struct WidgetGalleryView: View {
    private let calendar = Calendar.current
    private var now: Date {
        calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    }
    private var sample: WidgetDay { WidgetSnapshot.sample(now: now, calendar: calendar).day(at: now, calendar: calendar) }
    private var empty: WidgetDay { WidgetSnapshot.placeholder(now: now).day(at: now, calendar: calendar) }
    private let copy = WidgetCopy()

    var body: some View {
        if let only = UITestMode.widgetOnly {
            ZStack {
                Theme.Colors.groundOuter.ignoresSafeArea()
                gallery.environment(\.widgetGalleryFilter, only)
            }
            .preferredColorScheme(.dark)
        } else {
            ScrollView { gallery.padding(16) }
                .background(Theme.Colors.groundOuter.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
    }

    private var gallery: some View {
        Group {
            VStack(alignment: .leading, spacing: 18) {
                section("Hoy") {
                    home("widget.today.small", width: 170) { TodaySmallView(day: sample, copy: copy) }
                    home("widget.today.small.empty", width: 170) { TodaySmallView(day: empty, copy: copy) }
                    home("widget.today.medium", width: 364) { TodayMediumView(day: sample, copy: copy) }
                    home("widget.today.medium.empty", width: 364) { TodayMediumView(day: empty, copy: copy) }
                }
                section("Meta") {
                    home("widget.goal.small", width: 170) {
                        GoalSmallView(day: sample, goal: sample.goal(id: "sample-goal"), copy: copy)
                    }
                    home("widget.goal.small.empty", width: 170) {
                        GoalSmallView(day: empty, goal: nil, copy: copy)
                    }
                }
                section("Pantalla de bloqueo") {
                    lock("widget.lock.inline", width: 300, height: 26) { LockInlineView(day: sample, copy: copy) }
                    lock("widget.lock.rectangular", width: 172, height: 76) {
                        LockRectangularView(day: sample, copy: copy)
                    }
                    lock("widget.lock.rectangular.empty", width: 172, height: 76) {
                        LockRectangularView(day: empty, copy: copy)
                    }
                    lock("widget.lock.circular", width: 76, height: 76) { LockCircularView(day: sample) }
                }
                section("Centro de control") { controlMock }
                section("Live Activity del sueño") {
                    live("widget.live.consolidating", .init(phase: .consolidating, night: 0))
                    live("widget.live.done", .init(phase: .done, night: 13))
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if UITestMode.widgetOnly == nil {
                Text(title).font(Theme.Type_.label).kerning(0.66).textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.textFaint)
            }
            content()
        }
    }

    /// Pantalla de inicio: contenedor 22pt con el fondo del sistema de diseño.
    private func home<Content: View>(_ id: String, width: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: width, height: 170)
            .background(
                ZStack {
                    Theme.Colors.bg
                    RadialGradient(colors: [Theme.Colors.groundInner.opacity(0.9), Theme.Colors.bg.opacity(0)],
                                   center: UnitPoint(x: 0.2, y: 0.0), startRadius: 0, endRadius: 220)
                })
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .galleryItem(id)
    }

    /// Pantalla de bloqueo: tinta blanca sobre un fondo de wallpaper oscuro.
    private func lock<Content: View>(_ id: String, width: CGFloat, height: CGFloat,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .padding(12)
            .background(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.06)],
                                       startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .galleryItem(id)
    }

    /// Maqueta del control (el Centro de control real lo pinta iOS).
    private var controlMock: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(white: 0.22)).frame(width: 64, height: 64)
                Image(systemName: "waveform").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
            }
            Text(WidgetCopy.talk).font(Theme.Type_.body).foregroundStyle(.white)
        }
        .padding(14)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .galleryItem("widget.control.talk")
    }

    private func live(_ id: String, _ state: SleepActivityAttributes.ContentState) -> some View {
        SleepActivityView(selfName: "Budosky", state: state)
            .frame(width: 370)
            .background(Theme.Colors.bg)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .galleryItem(id)
    }
}

private struct WidgetGalleryFilterKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var widgetGalleryFilter: String? {
        get { self[WidgetGalleryFilterKey.self] }
        set { self[WidgetGalleryFilterKey.self] = newValue }
    }
}

private struct GalleryItem: ViewModifier {
    @Environment(\.widgetGalleryFilter) private var filter
    let id: String

    func body(content: Content) -> some View {
        if filter == nil || filter == id {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(id)
        }
    }
}

extension View {
    func galleryItem(_ id: String) -> some View { modifier(GalleryItem(id: id)) }
}
