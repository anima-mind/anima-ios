// SleepActivityController.swift — la Live Activity del sueño cuando corre en
// foreground (fallback al abrir o "Simular una noche"). iOS no deja abrirla
// desde background: el BGProcessingTask nocturno no la usa.

import ActivityKit
import Foundation
import AnimaKit

@MainActor
final class SleepActivityController {
    private var activity: Activity<SleepActivityAttributes>?

    func start(selfName: String) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: SleepActivityAttributes.ContentState(phase: .consolidating, night: 0),
                                      staleDate: Date().addingTimeInterval(30 * 60))
        activity = try? Activity.request(attributes: SleepActivityAttributes(selfName: selfName), content: content)
    }

    /// "Noche #N lista" (queda un rato en la pantalla de bloqueo) o se retira si no terminó.
    func finish(completed: Bool, night: Int) async {
        guard let current = activity else { return }
        self.activity = nil
        // Activity no es Sendable; el handle ya salió del controlador (nadie más lo usa).
        nonisolated(unsafe) let activity = current
        let state = SleepActivityAttributes.ContentState(phase: completed ? .done : .interrupted, night: night)
        await activity.end(ActivityContent(state: state, staleDate: nil),
                           dismissalPolicy: completed ? .after(Date().addingTimeInterval(20 * 60)) : .immediate)
    }
}
