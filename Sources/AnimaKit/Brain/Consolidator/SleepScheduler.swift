// SleepScheduler.swift — el sueño se programa como BGProcessingTask (§5.4):
// requiresExternalPower ⇒ el ciclo corre al CARGAR el teléfono. iOS decide
// cuándo (best-effort, puede no correr días), así que el fallback foreground es
// obligatorio: si >48h sin ciclo completo, se corre al abrir la app. En macOS y
// en tests no hay BGTaskScheduler: la ejecución es directa (Consolidator.cycle).
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

    public init(requiresExternalPower: Bool = true,
                requiresNetworkConnectivity: Bool = true,
                foregroundFallbackInterval: TimeInterval = 48 * 3600) {
        self.requiresExternalPower = requiresExternalPower
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.foregroundFallbackInterval = foregroundFallbackInterval
    }

    /// Por modo de operación (§4.9): si el sueño corre en el teléfono (Híbrido /
    /// Solo teléfono) el BGProcessingTask no exige red — gratis y offline.
    public init(selector: ProviderSelector, requiresExternalPower: Bool = true,
                foregroundFallbackInterval: TimeInterval = 48 * 3600) {
        self.init(requiresExternalPower: requiresExternalPower,
                  requiresNetworkConnectivity: selector.sleepRequiresNetwork,
                  foregroundFallbackInterval: foregroundFallbackInterval)
    }

    /// El sueño es la vía preferida, no la única: si pasaron más de 48h sin ciclo
    /// completo, hay que correrlo en foreground (best-effort, presupuesto reducido).
    public func shouldRunForegroundFallback(lastCycleAt: Date?, now: Date = Date()) -> Bool {
        guard let lastCycleAt else { return true }
        return now.timeIntervalSince(lastCycleAt) > foregroundFallbackInterval
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

    /// Encola el próximo ciclo (al ir a background).
    public func submit() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = requiresExternalPower
        request.requiresNetworkConnectivity = requiresNetworkConnectivity
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}

/// Puente entre el runner del BGProcessingTask (registrado en app launch) y el
/// Consolidator (cableado más tarde, cuando hay token). Thread-safe.
public final class ConsolidatorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var consolidator: Consolidator?
    private var scheduler: SleepScheduler?
    /// Ciclo COMPLETO (BGTask o fallback foreground) → el aviso de despertar (batch 8 #7).
    private var onCompleted: (@Sendable (Consolidator.CycleReport, Int) async -> Void)?

    public init() {}

    public func set(_ consolidator: Consolidator, scheduler: SleepScheduler,
                    onCompleted: (@Sendable (Consolidator.CycleReport, Int) async -> Void)? = nil) {
        lock.lock()
        self.consolidator = consolidator
        self.scheduler = scheduler
        self.onCompleted = onCompleted
        lock.unlock()
    }

    private func current() -> (Consolidator, SleepScheduler, (@Sendable (Consolidator.CycleReport, Int) async -> Void)?)? {
        lock.lock(); defer { lock.unlock() }
        guard let consolidator, let scheduler else { return nil }
        return (consolidator, scheduler, onCompleted)
    }

    @discardableResult
    public func run(isExpired: @escaping @Sendable () -> Bool) async -> Bool {
        guard let (consolidator, scheduler, onCompleted) = current() else { return false }
        guard let report = await scheduler.runReport(consolidator, isExpired: isExpired) else { return false }
        if report.completed, let onCompleted {
            await onCompleted(report, await consolidator.successfulCycles())
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
