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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()
        AppModel.registerConsolidationTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .task { await app.bootstrap() }
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { app.scheduleConsolidation() }
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
    @Published private(set) var memoryModel: MemoryBrowserViewModel?
    @Published private(set) var approvalsModel: ApprovalsInboxViewModel?
    @Published private(set) var goalsModel: GoalsViewModel?
    let confirmation = ConfirmationCenter()

    private let keychain = KeychainStore()
    private var store: SymbolicStore?
    private var telemetry: Telemetry?
    private var configProvider: FirebaseConfigProvider?
    // Fase 2: el brain, la cola de candidatos y el sueño.
    private var brain: Brain?
    private var inbox: ConsolidationInbox?
    private var consolidator: Consolidator?
    private let sleepScheduler = SleepScheduler()
    // Fase 3: la identidad viva y el registro de lo Real.
    private var selfModel: SelfModel?
    private var realRegister: RealRegister?
    // Fase 4: el deseo del Otro y el motor del pulso.
    private var otherModel: OtherModel?
    private var desireEngine: DesireEngine?

    /// Consolidator vivo del proceso, para que el runner del BGProcessingTask
    /// (registrado en app launch) lo alcance cuando ya esté cableado.
    static let shared = ConsolidatorHolder()

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
            self.brain = Brain(queue: queue)
            self.inbox = ConsolidationInbox(queue: queue)
            // Fase 3 (§5.5, §5.6): identidad viva + registro de lo Real.
            let selfModel = SelfModel(queue: queue, notifier: UserNotificationApprovalNotifier())
            self.selfModel = selfModel
            self.realRegister = RealRegister(queue: queue)
            // Fase 4 (§5.8): el modelo del deseo del Otro y su vista de metas.
            let otherModel = OtherModel(queue: queue)
            self.otherModel = otherModel
            self.goalsModel = GoalsViewModel(otherModel: otherModel)
            self.approvalsModel = ApprovalsInboxViewModel(selfModel: selfModel, otherModel: otherModel)
            _ = await selfModel.expireStale()   // fail-closed al abrir la app (§5.5)
            self.settingsModel = SettingsViewModel(keychain: keychain, telemetry: telemetry)
            if let brain = self.brain { self.memoryModel = MemoryBrowserViewModel(brain: brain) }
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
            confirmation: confirmation,
            brain: brain,
            inbox: inbox,
            selfModel: selfModel,
            realRegister: realRegister)

        // El Consolidator (§5.4) para el sueño: Haiku por el mismo dial. Fase 4: la
        // extracción de Stated Goals es una etapa nueva del ciclo (§5.8).
        if let brain {
            let consolidator = Consolidator(brain: brain, queue: store.database, provider: ClaudeProvider(),
                                            router: router, authMode: authMode, token: token, telemetry: telemetry,
                                            selfModel: selfModel, realRegister: realRegister, otherModel: otherModel)
            self.consolidator = consolidator
            Self.shared.set(consolidator, scheduler: sleepScheduler)
            await runForegroundFallbackIfNeeded(consolidator)
        }

        // El DesireEngine (§5.8): pulso ≤4/día contra el estado real del teléfono.
        let sessionId = (try? store.startSession()) ?? UUID().uuidString
        var desireEngine: DesireEngine?
        if let otherModel {
            let engine = DesireEngine(otherModel: otherModel, environment: SystemObservableEnvironment(),
                                      queue: store.database, provider: ClaudeProvider(), router: router,
                                      authMode: authMode, token: token, store: store, telemetry: telemetry)
            self.desireEngine = engine
            desireEngine = engine
            // Pulso al abrir la app (§5.8): reconcilia brechas contra el presupuesto.
            let sid = sessionId
            Task.detached { _ = try? await engine.pulse(sessionId: sid) }
        }

        chatModel = ChatViewModel(loop: loop, sessionId: sessionId, desireEngine: desireEngine)
        phase = .ready
    }

    /// Fallback foreground (§5.4): si pasaron >48h sin ciclo completo, se corre al
    /// abrir la app (best-effort, no bloqueante).
    private func runForegroundFallbackIfNeeded(_ consolidator: Consolidator) async {
        let last = await consolidator.lastCycleAt()
        guard sleepScheduler.shouldRunForegroundFallback(lastCycleAt: last) else { return }
        let scheduler = sleepScheduler
        Task.detached { await scheduler.runResumable(consolidator) }
    }

    /// Registro del BGProcessingTask (§5.4). Se llama en app launch; el runner
    /// alcanza el Consolidator vía el holder compartido cuando ya esté cableado.
    static func registerConsolidationTask() {
        #if os(iOS)
        SleepScheduler().register { task in
            // BGProcessingTask no es Sendable; se cruza al Task deliberadamente
            // (patrón sancionado de Apple para el expirationHandler + trabajo async).
            nonisolated(unsafe) let task = task
            let expired = ExpirationFlag()
            task.expirationHandler = { expired.mark() }
            Task {
                let success = await AppModel.shared.run(isExpired: { expired.value })
                task.setTaskCompleted(success: success)
            }
        }
        #endif
    }

    /// Encola el próximo ciclo al ir a background (el sueño corre al cargar).
    func scheduleConsolidation() {
        #if os(iOS)
        sleepScheduler.submit()
        #endif
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
                TabView {
                    ChatView(model: chat)
                        .confirmationOverlay(app.confirmation)
                        .tabItem { Label("Chat", systemImage: "bubble.left") }
                    if let memory = app.memoryModel {
                        MemoryBrowserView(model: memory)
                            .tabItem { Label("Memoria", systemImage: "brain") }
                    }
                    if let goals = app.goalsModel {
                        GoalsView(model: goals)
                            .tabItem { Label("Metas", systemImage: "target") }
                    }
                    if let approvals = app.approvalsModel {
                        ApprovalsInboxView(model: approvals)
                            .tabItem { Label("Aprobaciones", systemImage: "checkmark.seal") }
                            .badge(approvals.badgeCount)
                    }
                    if let settings = app.settingsModel {
                        SettingsView(model: settings)
                            .tabItem { Label("Ajustes", systemImage: "gearshape") }
                    }
                }
                .tint(Theme.Colors.accent)
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
