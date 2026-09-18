// ChatView.swift — chat con streaming token a token, thinking summarized
// colapsable y estados de error visibles (§6, Fase 0). Usa los tokens de Theme
// (dark-only; acento solo como línea/glow, nunca fill).

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class ChatViewModel: ObservableObject {
    public struct DisplayMessage: Identifiable, Sendable {
        public let id = UUID()
        public var role: Message.Role
        public var text: String = ""
        public var thinking: String = ""
        public var isError: Bool = false
        public var isStreaming: Bool = false
        public var isRefusal: Bool = false
    }

    @Published public var messages: [DisplayMessage] = []
    @Published public var input: String = ""
    @Published public var isStreaming: Bool = false
    @Published public var errorText: String?

    private let loop: AgentLoop
    private let sessionId: SessionID

    public init(loop: AgentLoop, sessionId: SessionID) {
        self.loop = loop
        self.sessionId = sessionId
    }

    public func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        errorText = nil
        messages.append(DisplayMessage(role: .user, text: text))

        var assistant = DisplayMessage(role: .assistant, isStreaming: true)
        messages.append(assistant)
        let index = messages.count - 1
        isStreaming = true

        for await event in await loop.run(sessionId: sessionId, userText: text) {
            switch event {
            case .textDelta(let d):
                assistant.text += d
            case .thinkingDelta(let d):
                assistant.thinking += d
            case .refused:
                assistant.isRefusal = true
                if assistant.text.isEmpty { assistant.text = "(respuesta rechazada por seguridad)" }
            case .error(let message):
                assistant.isError = true
                errorText = message
                if assistant.text.isEmpty { assistant.text = message }
            case .stopped(let stop):
                errorText = "Turno detenido: \(stop)"
            case .toolStarted, .toolFinished, .assistantMessage, .turnFinished:
                break
            }
            assistant.isStreaming = true
            if messages.indices.contains(index) { messages[index] = assistant }
        }

        assistant.isStreaming = false
        if messages.indices.contains(index) { messages[index] = assistant }
        isStreaming = false
    }
}

public struct ChatView: View {
    @ObservedObject private var model: ChatViewModel

    public init(model: ChatViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                if let error = model.errorText {
                    errorBanner(error)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.stack) {
                        ForEach(model.messages) { bubble($0) }
                    }
                    .padding(Theme.Space.screenInset)
                }
                composer
            }
        }
    }

    private func bubble(_ message: ChatViewModel.DisplayMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.thinking.isEmpty {
                DisclosureGroup {
                    Text(message.thinking)
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textFaint)
                } label: {
                    Text("Razonamiento")
                        .font(Theme.Type_.label)
                        .textCase(.uppercase)
                        .kerning(0.66)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
                .tint(Theme.Colors.accent)
            }
            Text(message.text)
                .font(Theme.Type_.body)
                .foregroundStyle(message.isError ? Theme.Colors.textMuted : Theme.Colors.text)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(Theme.Space.cardPad)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(message.isStreaming ? Theme.Colors.accent : Theme.Colors.border,
                                      lineWidth: Theme.Stroke.hairline)
                )
        )
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.accentText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.cardPad)
            .background(Theme.Colors.tint)
    }

    private var composer: some View {
        HStack(spacing: Theme.Space.stack) {
            TextField("Mensaje", text: $model.input, axis: .vertical)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .padding(Theme.Space.cardPad)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline)
                )
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
            }
            .disabled(model.isStreaming)
        }
        .padding(Theme.Space.screenInset)
    }
}
#endif
