// SerialTaskChain.swift — trabajos async del MainActor uno detrás de otro, sin
// solaparse y sin esperar en bucle: cada llamada encadena su Task a la anterior
// (esperar un Task ya terminado no suspende; un `while let running` sobre el
// MainActor giraría para siempre → watchdog 0x8badf00d).

import Foundation

@MainActor
public final class SerialTaskChain {
    private var tail: Task<Void, Never>?

    public init() {}

    /// ¿Hay un trabajo en curso o en espera?
    public var isBusy: Bool { tail != nil }

    /// Corre `work` cuando terminen los encolados antes; vuelve al terminar el suyo.
    public func run(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
        if tail == task { tail = nil }
    }
}
