// ConfirmationCenter.swift — el `ask` in-chat de la PermissionPolicy (§5.7). El
// Sensorimotor llama `confirm(_:)` para toda acción eferente; esta clase publica
// la solicitud para que la UI muestre el sheet con el diff y resuelve con la
// decisión del dueño. Fail-closed: si ya hay una pendiente, la nueva se niega.

#if canImport(SwiftUI)
import SwiftUI

/// Lo que el dueño decide en el sheet.
public enum ConfirmationDecision: Sendable, Equatable {
    case cancel, once, always
}

@MainActor
public final class ConfirmationCenter: ObservableObject, ConfirmationProvider {
    @Published public var pending: ConfirmationRequest?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// "Autorizar siempre": el shell persiste la (tool, operación).
    public var onAlwaysAllow: ((ConfirmationRequest) -> Void)?

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
        resolve(approved ? .once : .cancel)
    }

    public func resolve(_ decision: ConfirmationDecision) {
        if decision == .always, let request = pending { onAlwaysAllow?(request) }
        pending = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: decision != .cancel)
    }
}

/// El sheet del `ask` (batch 5b #8): patrón del Mind sheet — surface, drag
/// indicator, alto a la medida del contenido —; título en label, el resumen,
/// qué toca, y tres decisiones de 44 pt: Autorizar (primaria, ancho completo),
/// Autorizar siempre (secundaria) y Cancelar (texto).
public struct ConfirmationSheet: View {
    private let request: ConfirmationRequest
    private let onDecision: (ConfirmationDecision) -> Void

    public init(request: ConfirmationRequest, onDecision: @escaping (ConfirmationDecision) -> Void) {
        self.request = request
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Confirmar acción")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            Text(request.summary)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("confirm.summary")
            HStack(spacing: Theme.Space.unit * 1.5) {
                Image(systemName: "hand.raised")
                    .font(Theme.Type_.label.weight(.light))
                Text(ToolNames.context(tool: request.tool, operation: request.operation))
            }
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.textFaint)
            VStack(spacing: Theme.Space.unit * 2) {
                Button { onDecision(.once) } label: {
                    Text("Autorizar")
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.accentText)
                        .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.icon))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("confirm.allow")
                Button { onDecision(.always) } label: {
                    Text("Autorizar siempre")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.text)
                        .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("confirm.always")
                Button { onDecision(.cancel) } label: {
                    Text("Cancelar")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("confirm.cancel")
            }
            .padding(.top, Theme.Space.unit)
        }
        .padding(.horizontal, Theme.Space.screenInset)
        .padding(.top, Theme.Space.sectionGap + 4)
        .padding(.bottom, Theme.Space.stack)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirm.sheet")
    }
}

/// Ajustes → Skills → Permisos: lo autorizado "siempre", revocable.
@MainActor
public final class AuthorizedActionsModel: ObservableObject {
    @Published public private(set) var entries: [AllowlistEntry] = []
    private let store: AuthorizedActionsStore

    public init(store: AuthorizedActionsStore) {
        self.store = store
        load()
    }

    public func load() {
        entries = store.entries.sorted { ($0.tool, $0.operation) < ($1.tool, $1.operation) }
    }

    public func revoke(_ entry: AllowlistEntry) {
        store.revoke(entry)
        load()
    }
}

public struct AuthorizedActionsSection: View {
    @ObservedObject var model: AuthorizedActionsModel

    public init(model: AuthorizedActionsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.unit * 2) {
            Text("Permisos")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            if model.entries.isEmpty {
                Text("Nada autorizado para siempre. Tus metas y recordatorios de Anima no piden confirmación; lo que toca tu agenda, tus recordatorios del iPhone o la cámara sí.")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("permissions.empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(model.entries, id: \.self) { entry in
                        HStack {
                            Text(ToolNames.context(tool: entry.tool, operation: entry.operation))
                                .font(Theme.Type_.secondary)
                                .foregroundStyle(Theme.Colors.text)
                            Spacer()
                            Button("Quitar") { model.revoke(entry) }
                                .font(Theme.Type_.secondary)
                                .foregroundStyle(Theme.Colors.accentText)
                                .frame(minHeight: Theme.minHitTarget)
                                .accessibilityIdentifier("permissions.revoke")
                        }
                        .padding(.horizontal, Theme.Space.cardPad)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            }
        }
        .onAppear { model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissions.section")
    }
}
#endif
