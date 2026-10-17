// SleepScheduler.swift — el sueño se programa como BGProcessingTask (§5.4):
// requiresExternalPower ⇒ el ciclo corre al CARGAR el teléfono, y nunca antes
// del próximo inicio de la "Hora de dormir" (SleepWindow, default 01:00–06:00).
// iOS decide cuándo (best-effort, puede no correr días), así que el fallback
// foreground es obligatorio: si >48h sin ciclo completo, se corre al abrir la
// app. En macOS y en tests no hay BGTaskScheduler: la ejecución es directa
// (Consolidator.cycle).
//
// Debug en device: forzar el task desde LLDB con
//   e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
//       _simulateLaunchForTaskWithIdentifier:@"mind.anima.consolidate"]

import Foundation
#if os(iOS)
import BackgroundTasks
#endif

public struct SleepScheduler: Sendable {
    public static let taskIdentifier = "mind.anima.consolidate"

    public let requiresExternalPower: Bool
    public let requiresNetworkConnectivity: Bool
    public let foregroundFallbackInterval: TimeInterval
    private let windowSource: @Sendable () -> SleepWindow
    public let calendar: Calendar
    private let clock: @Sendable () -> Date

    public init(requiresExternalPower: Bool = true,
                requiresNetworkConnectivity: Bool = true,
                foregroundFallbackInterval: TimeInterval = 48 * 3600,
                window: @escaping @Sendable () -> SleepWindow = { .default },
                calendar: Calendar = .autoupdatingCurrent,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.requiresExternalPower = requiresExternalPower
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.foregroundFallbackInterval = foregroundFallbackInterval
        self.windowSource = window
        self.calendar = calendar
        self.clock = now
    }

    /// Por modo de operación (§4.9): si el sueño corre en el teléfono (Híbrido /
    /// Solo teléfono) el BGProcessingTask no exige red — gratis y offline.
    public init(selector: ProviderSelector, requiresExternalPower: Bool = true,
                foregroundFallbackInterval: TimeInterval = 48 * 3600,
                window: @escaping @Sendable () -> SleepWindow = { .default },
                calendar: Calendar = .autoupdatingCurrent,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(requiresExternalPower: requiresExternalPower,
                  requiresNetworkConnectivity: selector.sleepRequiresNetwork,
                  foregroundFallbackInterval: foregroundFallbackInterval,
                  window: window, calendar: calendar, now: now)
    }

    /// La "Hora de dormir" vigente (se lee en cada decisión: un cambio en Ajustes aplica ya).
    public var window: SleepWindow { windowSource() }

    /// El sueño es la vía preferida, no la única. Dentro de la ventana, el
    /// fallback corre si esta noche aún no hubo ciclo completo; fuera, solo si
    /// pasaron más de 48h (para que las memorias no se queden sin procesar si
    /// el teléfono nunca carga de noche).
    public func shouldRunForegroundFallback(lastCycleAt: Date?, now: Date? = nil) -> Bool {
        let now = now ?? clock()
        guard let lastCycleAt else { return true }
        if let tonight = window.currentStart(containing: now, calendar: calendar), lastCycleAt < tonight {
            return true
        }
        return now.timeIntervalSince(lastCycleAt) > foregroundFallbackInterval
    }

    /// Lo que se le pide a iOS al encolar: dentro de la ventana, ya; fuera, no
    /// antes de su próximo inicio.
    public struct Request: Equatable, Sendable {
        public let earliestBeginDate: Date
        public let requiresExternalPower: Bool
        public let requiresNetworkConnectivity: Bool
    }

    public func request(now: Date? = nil) -> Request {
        let now = now ?? clock()
        let window = self.window
        let begin = window.contains(now, calendar: calendar) ? now : window.nextStart(after: now, calendar: calendar)
        return Request(earliestBeginDate: begin, requiresExternalPower: requiresExternalPower,
                       requiresNetworkConnectivity: requiresNetworkConnectivity)
    }

    /// Qué hace el runner del BGProcessingTask al arrancar.
    public enum LaunchDecision: Equatable, Sendable {
        case run
        /// Fuera de la ventana: se completa sin ciclo y se re-encola para su próximo inicio.
        case deferred(until: Date)
    }

    public func launchDecision(now: Date? = nil) -> LaunchDecision {
        let now = now ?? clock()
        let window = self.window
        guard window.contains(now, calendar: calendar) else {
            return .deferred(until: window.nextStart(after: now, calendar: calendar))
        }
        return .run
    }

    /// Corre el ciclo de forma reanudable, cortando en frontera de etapa cuando
    /// `isExpired` se vuelve true (el expirationHandler del BGProcessingTask).
    @discardableResult
    public func runResumable(_ consolidator: Consolidator,
                             isExpired: @escaping @Sendable () -> Bool = { false }) async -> Bool {
        await runReport(consolidator, isExpired: isExpired)?.completed ?? false
    }

    /// Igual, devolviendo el reporte del ciclo (nil si falló).
    public func runReport(_ consolidator: Consolidator,
                          isExpired: @escaping @Sendable () -> Bool = { false }) async -> Consolidator.CycleReport? {
        try? await consolidator.cycle(interrupting: { _ in isExpired() })
    }

    #if os(iOS)
    /// Registro en app launch. El `runner` recibe el BGProcessingTask; debe atar
    /// su expirationHandler a un flag y llamar `runResumable` con él.
    public func register(runner: @escaping @Sendable (BGProcessingTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            runner(processing)
        }
    }

    /// Encola el próximo ciclo (al ir a background, al cambiar la ventana o al
    /// diferir un arranque fuera de ella). Reemplaza el pendiente.
    public func submit() {
        let plan = request()
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = plan.earliestBeginDate
        request.requiresExternalPower = plan.requiresExternalPower
        request.requiresNetworkConnectivity = plan.requiresNetworkConnectivity
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}

/// De dónde salió un ciclo: el BGProcessingTask dentro de la ventana (durmió)
/// o el fallback foreground (no dice "Dormí").
public enum CycleOrigin: Sendable, Equatable {
    case sleep
    case fallback
}

/// Puente entre el runner del BGProcessingTask (registrado en app launch) y el
/// Consolidator (cableado más tarde, cuando hay token). Thread-safe.
public final class ConsolidatorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var consolidator: Consolidator?
    private var scheduler: SleepScheduler?
    /// Ciclo COMPLETO (BGTask o fallback foreground) → el aviso de despertar (batch 8 #7).
    private var onCompleted: (@Sendable (Consolidator.CycleReport, Int, CycleOrigin) async -> Void)?

    public init() {}

    public func set(_ consolidator: Consolidator, scheduler: SleepScheduler,
                    onCompleted: (@Sendable (Consolidator.CycleReport, Int, CycleOrigin) async -> Void)? = nil) {
        lock.lock()
        self.consolidator = consolidator
        self.scheduler = scheduler
        self.onCompleted = onCompleted
        lock.unlock()
    }

    private func current() -> (Consolidator, SleepScheduler, (@Sendable (Consolidator.CycleReport, Int, CycleOrigin) async -> Void)?)? {
        lock.lock(); defer { lock.unlock() }
        guard let consolidator, let scheduler else { return nil }
        return (consolidator, scheduler, onCompleted)
    }

    @discardableResult
    public func run(origin: CycleOrigin = .sleep, isExpired: @escaping @Sendable () -> Bool) async -> Bool {
        guard let (consolidator, scheduler, onCompleted) = current() else { return false }
        guard let report = await scheduler.runReport(consolidator, isExpired: isExpired) else { return false }
        if report.completed, let onCompleted {
            await onCompleted(report, await consolidator.successfulCycles(), origin)
        }
        return report.completed
    }
}

/// Flag que el expirationHandler del BGProcessingTask marca para cortar el ciclo
/// en frontera de etapa. Thread-safe.
public final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    public init() {}
    public var value: Bool { lock.lock(); defer { lock.unlock() }; return flagged }
    public func mark() { lock.lock(); flagged = true; lock.unlock() }
}
