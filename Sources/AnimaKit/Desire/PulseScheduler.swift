// PulseScheduler.swift — el pulso del deseo también en background (§5.8):
// BGAppRefreshTask `mind.anima.pulse`, pedido al ir a background con
// earliestBeginDate = ahora + 4h (iOS decide cuándo; best-effort). El trabajo
// (PulseRunner) es testeable sin BackgroundTasks: reconciliar recordatorios
// vencidos → pulse(origin: .background) → si hubo Intention, notificación local.
// Presupuesto ≤4/día y cooldown 48h los impone el DesireEngine (los mismos que
// el pulso al abrir la app).
//
// Debug en device: forzar el task desde LLDB con
//   e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
//       _simulateLaunchForTaskWithIdentifier:@"mind.anima.pulse"]

import Foundation
#if os(iOS)
import BackgroundTasks
#endif

public struct PulseScheduler: Sendable {
    public static let taskIdentifier = "mind.anima.pulse"

    public let interval: TimeInterval

    public init(interval: TimeInterval = 4 * 3600) {
        self.interval = interval
    }

    public func earliestBeginDate(now: Date = Date()) -> Date {
        now.addingTimeInterval(interval)
    }

    #if os(iOS)
    /// Registro en app launch. El runner debe llamar SIEMPRE `setTaskCompleted`.
    public func register(runner: @escaping @Sendable (BGAppRefreshTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            runner(refresh)
        }
    }

    /// Encola el próximo pulso (al ir a background y al terminar cada uno).
    public func submit(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = earliestBeginDate(now: now)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}

/// El trabajo de un pulso en background, sin dependencias de BackgroundTasks.
public struct PulseRunner: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var delivered: [ProactiveMessage]
        public var intentions: [Intention]
    }

    private let reconciler: ProactiveReconciler?
    private let engine: DesireEngine?
    private let scheduler: ProactiveScheduler?

    public init(reconciler: ProactiveReconciler?, engine: DesireEngine?, scheduler: ProactiveScheduler?) {
        self.reconciler = reconciler
        self.engine = engine
        self.scheduler = scheduler
    }

    @discardableResult
    public func run(sessionId: SessionID?) async -> Outcome {
        let delivered = await reconciler?.reconcileDueReminders(sessionId: sessionId) ?? []
        var intentions: [Intention] = []
        if let engine, !Task.isCancelled {
            intentions = (try? await engine.pulse(sessionId: sessionId, origin: .background)) ?? []
        }
        for intention in intentions {
            await scheduler?.notify(intention)
        }
        await scheduler?.sync()
        return Outcome(delivered: delivered, intentions: intentions)
    }
}
