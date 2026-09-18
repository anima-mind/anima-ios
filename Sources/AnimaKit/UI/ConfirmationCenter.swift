// ConfirmationCenter.swift — el `ask` in-chat de la PermissionPolicy (§5.7). El
// Sensorimotor llama `confirm(_:)` para toda acción eferente; esta clase publica
// la solicitud para que la UI muestre el sheet con el diff y resuelve con la
// decisión del dueño. Fail-closed: si ya hay una pendiente, la nueva se niega.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class ConfirmationCenter: ObservableObject, ConfirmationProvider {
    @Published public var pending: ConfirmationRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    public init() {}

    public nonisolated func confirm(_ request: ConfirmationRequest) async -> Bool {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                guard self.continuation == nil else {
                    cont.resume(returning: false)   // ya hay una pendiente → fail-closed
                    return
                }
                self.continuation = cont
                self.pending = request
            }
        }
    }

    public func resolve(_ approved: Bool) {
        pending = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: approved)
    }
}

public struct ConfirmationSheet: View {
    private let request: ConfirmationRequest
    private let onDecision: (Bool) -> Void

    public init(request: ConfirmationRequest, onDecision: @escaping (Bool) -> Void) {
        self.request = request
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("¿Autorizas esta acción?")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            Text(request.summary)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
            HStack(spacing: Theme.Space.stack) {
                Button("Cancelar") { onDecision(false) }
                    .foregroundStyle(Theme.Colors.textMuted)
                Spacer()
                Button("Autorizar") { onDecision(true) }
                    .foregroundStyle(Theme.Colors.accent)
            }
            .font(Theme.Type_.body)
        }
        .padding(Theme.Space.screenInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface)
    }
}
#endif
