// AnimaApp.swift — @main del app shell iOS (§3, §6 Fase 1). FirebaseApp.configure,
// snapshot de config congelado por sesión, y el cableado real del harness:
// KeychainStore → ClaudeProvider → SymbolicStore → WorkingMemory → Sensorimotor
// (7 tools) → AgentLoop → ChatView. El `ask` in-chat pasa por ConfirmationCenter.

import SwiftUI
import AnimaKit
import FirebaseCore

@main
struct AnimaApp: App {
    @StateObject private var app = AppModel()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .task { await app.bootstrap() }
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case needsToken
        case ready
        case misconfigured(String)
    }

    @Published var phase: Phase = .loading
    @Published private(set) var chatModel: ChatViewModel?
    @Published private(set) var settingsModel: SettingsViewModel?
    let confirmation = ConfirmationCenter()

    private let keychain = KeychainStore()
    private var store: SymbolicStore?
    private var telemetry: Telemetry?
    private var configProvider: FirebaseConfigProvider?

    func bootstrap() async {
        // Config congelada por sesión (fetch+activate una vez).
        let provider = await FirebaseConfigProvider.bootstrap()
        configProvider = provider

        // Base de datos única (GRDB) en el sandbox.
        do {
            let dbPath = Self.databasePath()
            let queue = try AnimaDatabase.makeQueue(path: dbPath)
            Self.protect(path: dbPath)
            let store = SymbolicStore(queue: queue)
            let telemetry = Telemetry(queue: queue)
            self.store = store
            self.telemetry = telemetry
            self.settingsModel = SettingsViewModel(keychain: keychain, telemetry: telemetry)
        } catch {
            phase = .misconfigured("No se pudo abrir la base de datos: \(error.localizedDescription)")
            return
        }

        await buildIfPossible()
    }

    /// Reintenta el cableado tras guardar el token en Settings.
    func refreshAfterToken() {
        Task { await buildIfPossible() }
    }

    private func buildIfPossible() async {
        guard let store, let telemetry, let configProvider else { return }
        guard let token = (try? keychain.read()), !token.isEmpty,
              let authMode = AuthMode.detect(fromToken: token) else {
            phase = .needsToken
            return
        }
        let snapshot = configProvider.snapshot()
        guard let providerConfig = snapshot.config(for: .anthropic) else {
            phase = .misconfigured("Falta la config del provider anthropic (Remote Config / defaults).")
            return
        }

        let router = ModelRouter(config: providerConfig)
        let loop = AgentLoop(
            provider: ClaudeProvider(),
            store: store,
            telemetry: telemetry,
            router: router,
            authMode: authMode,
            token: token,
            clientTools: Self.tools(),
            confirmation: confirmation)

        let sessionId = (try? store.startSession()) ?? UUID().uuidString
        chatModel = ChatViewModel(loop: loop, sessionId: sessionId)
        phase = .ready
    }

    /// Registro v1 de tools client-side (§5.7). Camera/audio: la captura la inicia
    /// el dueño desde la app (pendiente de verificación en device); el contrato y
    /// el pipeline puro ya viven en AnimaKit.
    static func tools() -> [any SensorimotorTool] {
        [
            CalendarTool(),
            RemindersTool(),
            NotesTool(),
            PhoneContextTool(),
            CameraTool(),
            AudioTool(),
        ]
    }

    private static func databasePath() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("anima.sqlite").path
    }

    /// NSFileProtectionComplete para el .sqlite (§8).
    private static func protect(path: String) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
    }
}

struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        switch app.phase {
        case .loading:
            ProgressView().preferredColorScheme(.dark)
        case .needsToken:
            if let settings = app.settingsModel {
                SettingsView(model: settings)
                    .onDisappear { app.refreshAfterToken() }
            }
        case .misconfigured(let reason):
            Text(reason).padding()
        case .ready:
            if let chat = app.chatModel {
                ChatView(model: chat)
                    .confirmationOverlay(app.confirmation)
            }
        }
    }
}

extension View {
    /// Presenta el sheet del `ask` cuando el ConfirmationCenter tiene pendiente.
    func confirmationOverlay(_ center: ConfirmationCenter) -> some View {
        modifier(ConfirmationOverlay(center: center))
    }
}

struct ConfirmationOverlay: ViewModifier {
    @ObservedObject var center: ConfirmationCenter

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { center.pending != nil },
            set: { if !$0 { center.resolve(false) } }
        )) {
            if let request = center.pending {
                ConfirmationSheet(request: request) { center.resolve($0) }
                    .presentationDetents([.medium])
            }
        }
    }
}
