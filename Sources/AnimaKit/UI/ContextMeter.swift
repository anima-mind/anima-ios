// ContextMeter.swift — el medidor de contexto bajo el header (batch 5b #4/#5):
// la regla del header se llena con el % del contexto del modelo activo. Sin rojo
// ni ámbar (el design system carga el estado en peso, opacidad y copy): normal =
// accent tenue; >70 % = accent pleno con glow; >90 % = el % visible + "casi
// lleno". Tap → sheet con el desglose y Compactar / Nueva conversación.

#if canImport(SwiftUI)
import SwiftUI

struct ContextMeter: View {
    let gauge: ContextGauge?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Space.unit * 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Colors.border)
                        Capsule()
                            .fill(Theme.Colors.accent.opacity(fillOpacity))
                            .frame(width: max(0, geo.size.width * (gauge?.fraction ?? 0)))
                            .shadow(color: Theme.Colors.accent.opacity(glow), radius: 3)
                    }
                }
                .frame(height: 2)
                Text(label)
                    .font(Theme.Type_.tabular(Theme.Type_.label))
                    .foregroundStyle(level == .normal ? Theme.Colors.textFaint : Theme.Colors.accentText)
                    .fixedSize()
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Contexto \(gauge?.percent ?? 0) por ciento")
        .accessibilityIdentifier("chat.contextMeter")
    }

    private var level: ContextGauge.Level { gauge?.level ?? .normal }

    private var label: String {
        guard let gauge else { return "contexto" }
        return level == .critical ? "\(gauge.percent) % · casi lleno" : "\(gauge.percent) %"
    }

    private var fillOpacity: Double { level == .normal ? 0.55 : 1 }
    private var glow: Double { level == .normal ? 0 : (level == .high ? 0.5 : 0.9) }
}

/// Desglose + acciones. Patrón del Mind sheet: surface, detents a la medida.
struct ContextSheet: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    static let initialHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Contexto")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            if let gauge = model.contextGauge {
                Text("\(gauge.percent) % lleno")
                    .font(Theme.Type_.tabular(Theme.Type_.cardTitle))
                    .foregroundStyle(Theme.Colors.text)
                    .accessibilityIdentifier("context.percent")
                Text("\(gauge.model) · \(gauge.summary)")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)
                VStack(spacing: 0) {
                    row("Instrucciones y herramientas", gauge.systemTokens)
                    Divider().background(Theme.Colors.border)
                    row("Memorias activadas", gauge.memoryTokens)
                    Divider().background(Theme.Colors.border)
                    row("Conversación", gauge.conversationTokens)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            }
            Button {
                Task {
                    await model.compact()
                    dismiss()
                }
            } label: {
                HStack {
                    Spacer()
                    if model.isCompacting {
                        BreathMark(size: 16, phase: .breathing)
                    }
                    Text(model.isCompacting ? "Compactando…" : "Compactar")
                    Spacer()
                }
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.accentText)
                .frame(height: Theme.minHitTarget)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.compactor == nil || model.isCompacting || model.isStreaming)
            .accessibilityIdentifier("context.compact")
            Button {
                dismiss()
                model.onNewConversation?()
            } label: {
                Text("Nueva conversación")
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.onNewConversation == nil || model.isStreaming)
            .accessibilityIdentifier("context.newConversation")
            Text("Compactar resume lo hablado y sigue desde el resumen. Tu memoria, metas y recordatorios no se tocan.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.screenInset)
        .padding(.top, Theme.Space.stack)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("context.sheet")
    }

    private func row(_ title: String, _ tokens: Int) -> some View {
        HStack {
            Text(title)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textFaint)
            Spacer()
            Text(ContextGauge.compact(tokens))
                .font(Theme.Type_.tabular(Theme.Type_.secondary))
                .foregroundStyle(Theme.Colors.textMuted)
        }
        .frame(height: 36)
        .padding(.horizontal, Theme.Space.cardPad)
    }
}
#endif
