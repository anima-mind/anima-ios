// AnimaApp.swift — @main del app shell iOS (§3, §6 Fase 1). FirebaseApp.configure,
// snapshot de config congelado por sesión, y el cableado real del harness:
// ProviderTokenStore → ProviderSelector (remoto Claude/OpenAI/Gemini u on-device, §4.9) → SymbolicStore → WorkingMemory → Sensorimotor
// (7 tools) → AgentLoop → ChatView. El `ask` in-chat pasa por ConfirmationCenter.

import SwiftUI
import Combine
import WidgetKit
import AnimaKit
import FirebaseCore

@main
struct AnimaApp: App {
    /// La MISMA instancia que alcanza el runner del BGProcessingTask (lanzamiento
    /// en background sin escena: el `.task` de la vista jamás corre).
    @StateObject private var app = AppModel.live
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // `--uitest` (XCUITest): sin Firebase ni red; estado aislado (UITestSupport).
        if UITestMode.isActive {
            UITestMode.resetIfRequested()
        } else {
            FirebaseApp.configure()
        }
        AppModel.registerConsolidationTask()
        AppModel.registerPulseTask()
        AnimaNotifications.install()
        // Botones de los widgets ejecutados en ESTE proceso (LiveActivityIntent):
        // se aplican ya con el mismo handler de las notificaciones.
        WidgetIntentBridge.shared.apply = { await AppModel.live.applyWidgetActionsFromIntent() }
    }

    var body: some Scene {
        WindowGroup {
            if UITestMode.showsWidgetGallery {
                WidgetGalleryView()
            } else {
                RootView(app: app)
                    .task { await app.ensureBootstrapped() }
                    .onOpenURL { app.handleOpenURL($0) }
                    .preferredColorScheme(.dark)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                app.markCleanShutdown()
                app.scheduleConsolidation()
                app.schedulePulse()
                Task { await app.publishWidgets() }
            }
            app.glassesForeground(phase == .active)
            // Un ciclo nocturno pudo correr en background: el badge/Mind sheet relee el self.
            if phase == .active {
                app.refreshMind()
                app.didBecomeActive()
            }
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
    /// Primer arranque (handoff): landing → onboarding hasta que el Birth corra.
    @Published var onboarded: Bool = AppModel.onboardingDefaults.hasOnboarded
    /// "Repetir onboarding" desde Ajustes (re-corre el flujo sin borrar memoria).
    @Published var replayingOnboarding = false
    @Published private(set) var chatModel: ChatViewModel?
    @Published private(set) var settingsModel: SettingsViewModel?
    @Published private(set) var memoryModel: MemoryBrowserViewModel?
    @Published private(set) var approvalsModel: ApprovalsInboxViewModel?
    @Published private(set) var goalsModel: GoalsViewModel?
    @Published private(set) var remindersModel: RemindersViewModel?
    /// Aprobaciones pendientes: badge de la tab Ajustes y aviso sobre el chat.
    @Published private(set) var pendingApprovals = 0
    private var approvalsWatch: AnyCancellable?
    private let connectivity = ConnectivityMonitor()
    /// Último estado de red (el chat se re-cablea: lo hereda al crearse).
    private var offline = false
    let confirmation = ConfirmationCenter()
    /// "Autorizar siempre" (sheet de confirmación), revocable en Ajustes → Skills.
    private let authorized = AuthorizedActionsStore(defaults: UITestMode.isActive ? UITestMode.defaults : .standard)
    /// Identidad (Sign in with Apple vía Firebase Auth). Se crea en bootstrap,
    /// tras FirebaseApp.configure; es opcional y jamás bloquea el uso.
    private(set) var account: AccountViewModel?

    private let keychain = UITestMode.isActive
        ? ProviderTokenStore(service: UITestMode.keychainService)
        : ProviderTokenStore()
    private var store: SymbolicStore?
    private var telemetry: Telemetry?
    private var configProvider: (any RemoteConfigProviding)?
    // Fase 2: el brain, la cola de candidatos y el sueño.
    private var brain: Brain?
    private var inbox: ConsolidationInbox?
    private var consolidator: Consolidator?
    /// Se re-crea por modo (§4.9): si el sueño es local, el BGTask no exige red.
    private var sleepScheduler = SleepScheduler()
    // Fase 3: la identidad viva y el registro de lo Real.
    private var selfModel: SelfModel?
    private var realRegister: RealRegister?
    // Fase 4: el deseo del Otro y el motor del pulso.
    private var otherModel: OtherModel?
    private var desireEngine: DesireEngine?
    // Capa proactiva: recordatorios de Anima, notificaciones locales y la
    // reconciliación de lo vencido mientras la app no miraba.
    private var reminderStore: AnimaReminderStore?
    /// Widgets: snapshot JSON en el App Group + la cola de sus botones.
    private var widgetPublisher: WidgetPublisher?
    private var widgetDrain: Task<Void, Never>?
    /// Live Activity del sueño en foreground.
    private let sleepActivity = SleepActivityController()
    private var proactiveScheduler: ProactiveScheduler?
    private var reconciler: ProactiveReconciler?
    /// Deep link que llegó antes de que el chat estuviera cableado (cold launch
    /// desde una notificación): se abre al terminar el cableado.
    private var pendingLink: AnimaDeepLink?
    // §5.7: skills = conocimiento procedural en Documents/skills (visible en Files).
    private var skillEngine: SkillEngine?
    // Track G (doc 05): el segundo cuerpo opcional. Sin gafas todo sigue igual.
    private var glassesBody: GlassesBody?
    private var glassesActivation: GlassesActivation?
    @Published private(set) var glassesModel: GlassesViewModel?
    /// G1: las tools de gafas se declaran con este proxy; la superficie se enchufa al cablear.
    private let glassesHost = LateBoundGlassesHost()
    private let surfaceRouter = SurfaceRouter()
    private var glassesSurface: GlassesHUDSurface?
    private var activeSessionId: SessionID?
    private var previousSessionId: SessionID?
    /// Tab visible (el deep link "ver en el teléfono" salta al Chat).
    @Published var selectedTab: AppTab = .chat
    /// "Hey Meta, start Anima" (DAT 1.0): el stream se abre en el init — ANTES de
    /// la UI — para capturar el cold-launch por voz; el cuerpo se enchufa en bootstrap.
    let voiceInvocations: VoiceInvocationOrchestrator

    init() {
        voiceInvocations = VoiceInvocationOrchestrator(port: Self.makeVoiceInvocationsPort())
        voiceInvocations.start()
        connectivity.start { [weak self] offline in
            guard let self else { return }
            self.offline = offline
            Task { await self.chatModel?.setOffline(offline) }
        }
        let authorized = self.authorized
        confirmation.onAlwaysAllow = { request in
            authorized.allow(AllowlistEntry(tool: request.tool, operation: request.operation))
        }
    }

    /// Consolidator vivo del proceso, para que el runner del BGProcessingTask
    /// (registrado en app launch) lo alcance cuando ya esté cableado.
    static let shared = ConsolidatorHolder()

    /// Instancia única del proceso: la escena, los BGTasks (sueño y pulso) y las
    /// acciones de notificación comparten el mismo cableado (un solo SelfModel,
    /// un solo Consolidator).
    static let live = AppModel()

    private var bootstrapTask: Task<Void, Never>?

    /// Idempotente: la escena (`.task`) y el runner del BGTask lo llaman; el
    /// cableado ocurre UNA vez. Sin esto, un lanzamiento en background (iOS
    /// despierta la app para el sueño SIN escena) encontraba el holder vacío y
    /// el ciclo nocturno jamás corría por esa vía.
    /// `configFetchTimeout`: tope del fetch de Remote Config si este llamado es
    /// el que arranca el proceso (acción de notificación en background).
    func ensureBootstrapped(configFetchTimeout: TimeInterval? = nil) async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { await self.bootstrap(configFetchTimeout: configFetchTimeout) }
        bootstrapTask = task
        await task.value
    }

    /// Defaults del onboarding/modo: `.standard`, o la suite efímera en `--uitest`.
    static let onboardingDefaults = OnboardingDefaults(
        defaults: UITestMode.isActive ? UITestMode.defaults : .standard)

    /// Disponibilidad del modelo local: en vivo, o forzada a `.available` en `--uitest`.
    static let availability: @Sendable () -> OnDeviceAvailability = {
        UITestMode.isActive ? UITestMode.forcedAvailability : OnDeviceAvailability.current()
    }

    func bootstrap(configFetchTimeout: TimeInterval? = nil) async {
        if UITestMode.isActive {
            account = AccountViewModel(provider: PreviewAccountProvider(state: .signedOut),
                                       profile: AccountProfileStore(defaults: UITestMode.defaults))
            configProvider = UITestMode.bundledConfig()
        } else {
            account = AccountViewModel(provider: FirebaseAccountProvider())
            // Config congelada por sesión (fetch+activate una vez).
            let provider: FirebaseConfigProvider = await FirebaseConfigProvider.bootstrap(
                fetchTimeout: configFetchTimeout)
            configProvider = provider
        }

        // Base de datos única (GRDB) en el contenedor del App Group (mudanza
        // única y verificada desde Documents; ante cualquier fallo, la vieja).
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
            let realRegister = RealRegister(queue: queue)
            self.realRegister = realRegister
            // Track G: el cuerpo-gafas (DAT) — selector y sesión únicos en GlassesBody.
            let glassesBody = GlassesBody(runtime: Self.makeGlassesRuntime(), realRegister: realRegister,
                                          diagnostics: .shared)
            let activation = GlassesActivation(body: glassesBody, reentry: {
                await MainActor.run { HandoffNotifications.post(.glasses, body: HandoffNotifications.reentryText) }
            }, events: { [telemetry] row in
                try? telemetry.recordGlassesEvent(row)
            })
            self.glassesBody = glassesBody
            self.glassesActivation = activation
            self.glassesModel = GlassesViewModel(body: glassesBody, activation: activation, host: glassesHost)
            glassesModel?.observeVoiceInvocations(voiceInvocations)
            voiceInvocations.bind(target: activation, record: { [telemetry] row in
                try? telemetry.recordVoiceInvocation(row)
            })
            Task {
                await glassesBody.setHandlers(onAction: nil, onExit: { Task { await activation.userExited() } })
                await glassesBody.start()
                await activation.start()
            }
            // Fase 4 (§5.8): el modelo del deseo del Otro y su vista de metas.
            let otherModel = OtherModel(queue: queue)
            self.otherModel = otherModel
            self.goalsModel = GoalsViewModel(otherModel: otherModel)
            let approvals = ApprovalsInboxViewModel(selfModel: selfModel, otherModel: otherModel)
            self.approvalsModel = approvals
            approvalsWatch = approvals.$pending.combineLatest(approvals.$pendingGoals)
                .map { $0.count + $1.count }
                .removeDuplicates()
                .sink { [weak self] count in
                    self?.pendingApprovals = count
                    self?.chatModel?.pendingApprovals = count
                }
            let reminderStore = AnimaReminderStore(queue: queue)
            let notifications: any LocalNotificationScheduler = UITestMode.isActive && !UITestMode.usesRealNotifications
                ? FakeNotificationScheduler(status: .denied) : UserNotificationsScheduler()
            self.reminderStore = reminderStore
            let preference = ProactivePreference(defaults: UITestMode.isActive ? UITestMode.defaults : .standard)
            self.proactiveScheduler = ProactiveScheduler(scheduler: notifications, reminders: reminderStore,
                                                         otherModel: otherModel,
                                                         selfName: { await selfModel.name() },
                                                         preference: preference)
            self.reconciler = ProactiveReconciler(reminders: reminderStore, otherModel: otherModel, store: store)
            if let widgetStore = WidgetSnapshotStore.shared() {
                let publisher = WidgetPublisher(
                    builder: WidgetSnapshotBuilder(reminders: reminderStore, otherModel: otherModel,
                                                   selfModel: selfModel),
                    store: widgetStore, reload: { WidgetCenter.shared.reloadAllTimelines() })
                self.widgetPublisher = publisher
                // Cada cambio de recordatorios/metas pasa por sync(): ahí se republica.
                await proactiveScheduler?.setAfterSync { await publisher.publish() }
            }
            let notificationsModel = NotificationsSettingsModel(scheduler: notifications, reminders: reminderStore,
                                                                preference: preference)
            notificationsModel.openSystemSettings = Self.openNotificationSettings
            let proactive = self.proactiveScheduler
            notificationsModel.onEnabledChanged = { await proactive?.sync() }
            goalsModel?.onCheckInChanged = { await proactive?.sync() }
            let remindersList = RemindersViewModel(store: reminderStore, otherModel: otherModel)
            remindersList.onChange = { [weak notificationsModel] in
                await proactive?.sync()
                await notificationsModel?.refresh()
            }
            remindersList.onOpenGoal = { [weak self] goalId in
                self?.selectedTab = .goals
                self?.goalsModel?.focus(goalId: goalId)
            }
            notificationsModel.openList = { [weak self] in self?.selectedTab = .reminders }
            self.remindersModel = remindersList
            if UITestMode.seedsGoal { await UITestMode.seedGoal(otherModel) }
            if UITestMode.seedsInferredGoal { await UITestMode.seedInferredGoal(otherModel) }
            if let seconds = UITestMode.seedReminderSeconds {
                await UITestMode.seedReminder(reminderStore, seconds: seconds)
            }
            _ = await selfModel.expireStale()   // fail-closed al abrir la app (§5.5)
            // Destilado v2 (campo batch 3): invalida UNA vez las memorias legacy que
            // eran preguntas del dueño o meta del asistente (bi-temporal, con razón).
            if let brain = self.brain {
                _ = try? await DistillMigration.runIfNeeded(queue: queue, brain: brain,
                                                            selfName: await selfModel.name())
            }
            let settings = SettingsViewModel(keychain: keychain, telemetry: telemetry,
                                             onboardingDefaults: Self.onboardingDefaults,
                                             availability: Self.availability)
            settings.onReplayOnboarding = { [weak self] in self?.startOnboardingReplay() }
            settings.account = account
            // Cambio de modo en Ajustes (§4.9): re-cablea el harness sin re-onboarding.
            settings.onModeChanged = { [weak self] _ in self?.refreshAfterToken() }
            // Skills: siembra de los ejemplos del bundle al primer arranque (dir vacío).
            let skillsDir = Self.skillsDirectory()
            try? SkillSeeder.seedIfEmpty(from: Bundle.main.url(forResource: "Skills", withExtension: nil),
                                         to: skillsDir)
            let skillEngine = SkillEngine(queue: queue, directory: skillsDir)
            self.skillEngine = skillEngine
            let skills = SkillsViewModel(engine: skillEngine, library: SkillLibrary(directory: skillsDir))
            skills.exampleMarkdown = Bundle.main.url(forResource: "Skills", withExtension: nil)
                .flatMap { try? String(contentsOf: $0.appendingPathComponent("nota-diaria.md"), encoding: .utf8) }
            skills.makeVoice = { Self.makePhoneVoice() }
            skills.permissions = AuthorizedActionsModel(store: authorized)
            settings.skills = skills
            settings.selfModel = selfModel
            settings.glasses = glassesModel
            settings.notifications = notificationsModel
            settings.approvals = approvals
            self.settingsModel = settings
            if let brain = self.brain {
                if UITestMode.seedsMemory { await UITestMode.seedMemory(brain) }
                self.memoryModel = MemoryBrowserViewModel(brain: brain)
            }
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

    // MARK: - Primer arranque / onboarding

    /// Fábrica del view model del flujo de 7 pasos, con el cableado real:
    /// Keychain para la key, config del provider para validar contra el API,
    /// y el SelfModel para sembrar el Birth.
    func makeOnboardingModel() -> OnboardingViewModel {
        let snapshot = configProvider?.snapshot()
        var apis: [ModelProvider: ProviderAPIConfig] = [:]
        for provider in ModelProvider.remoteCases {
            if let api = snapshot?.config(for: provider)?.api { apis[provider] = api }
        }
        let model = OnboardingViewModel(
            keychain: keychain,
            // `--uitest`: sin apis → el validador acepta offline con warning (sin red).
            apis: UITestMode.isActive ? [:] : apis,
            selfModel: selfModel,
            selfModelResolver: { [weak self] in
                guard let self else { return nil }
                await self.ensureBootstrapped()
                return await self.selfModel
            },
            defaults: Self.onboardingDefaults,
            isReplay: replayingOnboarding,
            account: account,
            availability: Self.availability
        ) { [weak self] in
            self?.completeOnboarding()
        }
        model.glasses = glassesModel
        return model
    }

    func completeOnboarding() {
        onboarded = true
        replayingOnboarding = false
        Task { await buildIfPossible() }
    }

    func startOnboardingReplay() {
        onboarded = false
        replayingOnboarding = true
    }

    /// Salida con el back chevron desde el primer paso.
    func exitOnboardingFlow() {
        if replayingOnboarding {
            // Cancela el replay: la mente ya había nacido.
            Self.onboardingDefaults.markOnboarded()
            onboarded = true
            replayingOnboarding = false
        }
    }

    private func buildIfPossible() async {
        guard let store, let telemetry, let configProvider else { return }
        let snapshot = configProvider.snapshot()
        let mode = Self.onboardingDefaults.modeStore.mode
        // Ajustes → Modelo valida las keys como el onboarding (`--uitest`: offline).
        var settingsAPIs: [ModelProvider: ProviderAPIConfig] = [:]
        for provider in ModelProvider.remoteCases where !UITestMode.isActive {
            if let api = snapshot.config(for: provider)?.api { settingsAPIs[provider] = api }
        }
        settingsModel?.apis = settingsAPIs
        let remoteKind = Self.onboardingDefaults.remoteStore.provider

        // Córtex remoto (Claude / OpenAI / Gemini): solo con token reconocible
        // para el provider activo. En `--uitest` el córtex es el guionado.
        let token = ((try? keychain.read(remoteKind)) ?? nil) ?? ""
        var remote: ProviderSelector.RemoteCortex?
        if UITestMode.isActive, let config = snapshot.config(for: remoteKind) {
            remote = .init(provider: UITestScriptedProvider(), router: ModelRouter(config: config),
                           authMode: .apiKey, token: "uitest", kind: remoteKind)
        } else {
            remote = RemoteCortexFactory.make(kind: remoteKind, config: snapshot.config(for: remoteKind),
                                              token: token)
        }
        // Córtex local (Apple Foundation Models): sin red, sin auth. La
        // disponibilidad se consulta en cada turno, jamás se asume.
        var local: ProviderSelector.LocalCortex?
        if let config = snapshot.config(for: .onDevice) {
            let cortex: Provider = UITestMode.isActive ? UITestScriptedProvider() : OnDeviceProvider.system()
            local = .init(provider: cortex, router: ModelRouter(config: config))
        }

        if mode.requiresToken, remote == nil {
            if remoteKind.authMode(forToken: token) == nil {
                phase = .needsToken
            } else {
                phase = .misconfigured("Falta la config del provider \(remoteKind.rawValue) (Remote Config / defaults).")
            }
            return
        }
        if mode == .onDeviceOnly, local == nil {
            phase = .misconfigured("Falta la config del provider on_device (Remote Config / defaults).")
            return
        }

        let selector = ProviderSelector(mode: mode, remote: remote, local: local,
                                        availability: Self.availability)
        sleepScheduler = SleepScheduler(selector: selector)

        var bodyStatus: (@Sendable () async -> String?)?
        if let body = glassesBody {
            bodyStatus = { await body.currentStatus().statusLine }
        }
        let loop = AgentLoop(
            selector: selector,
            store: store,
            telemetry: telemetry,
            clientTools: Self.tools(glasses: glassesHost, reminders: reminderStore, otherModel: otherModel,
                                    proactive: proactiveScheduler),
            // web_search deshabilitada: el round-trip de server_tool_use/pause_turn
            // manda wire format inválido (auditoría v1 gap #3); rehabilitar al arreglar.
            serverTools: [],
            // 5b #1: lo interno y reversible no pide ok; lo autorizado "siempre" tampoco.
            permissionPolicy: .app(ownerAllowlist: { [authorized] in authorized.entries }),
            // §8: la cámara de las gafas se confirma con pinch EN las gafas; el resto, sheet.
            confirmation: SurfaceConfirmationRouter(phone: confirmation, glasses: { [glassesHost] request in
                await glassesHost.confirm(request)
            }),
            brain: brain,
            inbox: inbox,
            selfModel: selfModel,
            realRegister: realRegister,
            skillEngine: skillEngine,
            bodyStatus: bodyStatus)

        // El Consolidator (§5.4) para el sueño: el selector decide dónde corre
        // (Híbrido / Solo teléfono → modelo local, gratis y sin red). Fase 4: la
        // extracción de Stated Goals es una etapa nueva del ciclo (§5.8).
        if let brain {
            let consolidator = Consolidator(brain: brain, queue: store.database, selector: selector,
                                            telemetry: telemetry, selfModel: selfModel,
                                            realRegister: realRegister, otherModel: otherModel)
            self.consolidator = consolidator
            Self.shared.set(consolidator, scheduler: sleepScheduler)
            // "Simular una noche" (Ajustes → Mente): el mismo ciclo, en foreground.
            let other = otherModel
            settingsModel?.nightSimulator = NightSimulator(consolidator: consolidator, goalCount: {
                await other?.allGoals().count ?? 0
            })
            settingsModel?.onNightStarted = { [weak self] in
                guard let self, !UITestMode.isActive else { return }
                Task { await self.sleepActivity.start(selfName: await self.selfModel?.name() ?? "Anima") }
            }
            settingsModel?.onNightSimulated = { [weak self] in
                Task { @MainActor in
                    if let self, !UITestMode.isActive {
                        await self.sleepActivity.finish(completed: true, night: await self.selfModel?.cycles() ?? 0)
                    }
                    await self?.publishWidgets()
                    await self?.memoryModel?.load()
                    await self?.goalsModel?.refresh()
                    await self?.approvalsModel?.refresh()
                    await self?.chatModel?.loadMind()
                }
            }
            // `--uitest`: sin sueño en foreground (turnos deterministas).
            if !UITestMode.isActive { await runForegroundFallbackIfNeeded(consolidator) }
        }

        // Taller de skills (FIX A): sesión EFÍMERA sobre el córtex activo — no
        // toca el SymbolicStore del hilo principal ni el inbox del sueño.
        let workshopSelf = selfModel
        settingsModel?.skills?.makeSession = { mode in
            try SkillWorkshopSession.make(selector: selector, telemetry: telemetry,
                                          selfModel: workshopSelf, mode: mode)
        }

        // El DesireEngine (§5.8): pulso ≤4/día contra el estado real del teléfono.
        let (sessionId, previousSession) = resolveSession(store)
        var desireEngine: DesireEngine?
        if let otherModel {
            let engine = DesireEngine(otherModel: otherModel,
                                      environment: SystemObservableEnvironment(otherModel: otherModel,
                                                                               mentions: MentionIndex(queue: store.database)),
                                      queue: store.database, selector: selector,
                                      store: store, telemetry: telemetry)
            self.desireEngine = engine
            desireEngine = engine
            // Pulso al abrir la app (§5.8): reconcilia brechas contra el presupuesto.
            // Un despertar en background NO lo corre: ese pulso es del BGTask y notifica.
            let sid = sessionId
            if !UITestMode.isActive, !Self.launchedInBackground {
                Task.detached { _ = try? await engine.pulse(sessionId: sid) }
            }
        }

        // El SelfModel vivo alimenta el badge, el Mind sheet ("noches") y el nombre del header.
        let chat = ChatViewModel(loop: loop, sessionId: sessionId, desireEngine: desireEngine,
                                 selfModel: selfModel)
        // El chat abre con lo vivido: la sesión reanudada (y la anterior, si es nueva).
        chat.loadHistory(current: (try? store.visibleTurns(sessionId: sessionId)) ?? [],
                         previous: previousSession.flatMap { try? store.visibleTurns(sessionId: $0) } ?? [],
                         boundaries: (try? store.boundaries(sessionId: sessionId)) ?? [])
        // Contexto (5b #4/#5): compactar con el córtex de ciclo, o conversación nueva.
        chat.compactor = ConversationCompactor(selector: selector, store: store, telemetry: telemetry)
        chat.onNewConversation = { [weak self] in self?.startNewConversation() }
        chat.glasses = glassesModel
        chat.voice = Self.makePhoneVoice()
        chat.pendingApprovals = pendingApprovals
        chat.usesRemoteConversation = mode != .onDeviceOnly
        chat.localModelAvailable = mode == .onDeviceOnly
        await chat.setOffline(offline)
        chat.onOpenApprovals = { [weak self] in self?.openApprovals() }
        // Solo-teléfono (FoundationModels) no ve imágenes: el menú de foto lo dice.
        chat.photosAvailable = mode != .onDeviceOnly
        if UITestMode.isActive { chat.injectedPhoto = { UITestMode.fixturePhoto() } }
        // El nombre/plasticidad ANTES de publicarlo: al re-cablear (fin del
        // onboarding, cambio de modo) la vista conserva su identidad y su `.task`
        // no vuelve a correr — sin esto el header quedaba con el nombre semilla.
        await chat.loadMind()
        await chat.refreshContext()
        surfaceRouter.register(chat)
        chatModel = chat
        await wireGlassesSurface(loop: loop, sessionId: sessionId)
        phase = .ready
        await approvalsModel?.refresh()
        await reconcileProactive()
        await applyWidgetActions()
        await publishWidgets()
        if let link = pendingLink {
            pendingLink = nil
            open(link)
        }
    }

    /// Recordatorios vencidos → mensajes de Anima en el chat + re-sync de las
    /// notificaciones locales (al abrir, al volver a foreground y en background).
    func reconcileProactive() async {
        guard let reconciler, let activeSessionId else { return }
        let delivered = await reconciler.reconcileDueReminders(sessionId: activeSessionId)
        chatModel?.appendProactive(delivered)
        await proactiveScheduler?.sync()
    }

    func didBecomeActive() {
        guard phase == .ready else { return }
        Task {
            await reconcileProactive()
            await approvalsModel?.refresh()
            await applyWidgetActions()
        }
    }

    // MARK: - Widgets

    /// Reescribe el snapshot del App Group y pide a WidgetKit repintar.
    func publishWidgets() async {
        await widgetPublisher?.publish()
    }

    /// Aplica la cola de botones de los widgets con el MISMO handler de las
    /// notificaciones. Serializado: nunca dos drenajes a la vez.
    func applyWidgetActions() async {
        while let running = widgetDrain { await running.value }
        guard reminderStore != nil, let inbox = WidgetActionInbox.shared(), !inbox.pending().isEmpty else { return }
        let handler = ProactiveActionHandler(reminders: reminderStore, otherModel: otherModel,
                                             scheduler: proactiveScheduler)
        let task = Task { @MainActor in
            await inbox.drain { await handler.handle($0.proactiveAction, note: ProactiveActionHandler.widgetNote) }
            await self.goalsModel?.refresh()
            await self.remindersModel?.refresh()
            await self.settingsModel?.notifications?.refresh()
            await self.publishWidgets()
        }
        widgetDrain = task
        await task.value
        widgetDrain = nil
    }

    /// El intent del widget corrió en el proceso de la app (posiblemente lanzada
    /// en background solo para esto): cablea con tope de config y aplica.
    func applyWidgetActionsFromIntent() async {
        await ensureBootstrapped(configFetchTimeout: RemoteConfigFetch.notificationActionTimeout)
        await applyWidgetActions()
    }

    /// "Nueva conversación" (medidor de contexto): cierra la sesión y abre otra;
    /// memoria, metas y recordatorios intactos. El chat arranca limpio.
    func startNewConversation() {
        guard let store, let fresh = try? store.beginNewConversation(after: activeSessionId) else { return }
        activeSessionId = fresh
        previousSessionId = nil
        Task {
            await buildIfPossible()
            chatModel?.markNewConversation()
        }
    }

    /// Aviso del chat → Ajustes → Mente ("Por aprobar").
    func openApprovals() {
        selectedTab = .settings
        settingsModel?.path = [.mind]
    }

    /// Sesión activa del proceso: se decide UNA vez al abrir (Recovery.decideLaunch:
    /// reanuda la última salvo >8 h sin actividad); los re-cableados la reusan.
    private func resolveSession(_ store: SymbolicStore) -> (SessionID, SessionID?) {
        if let activeSessionId { return (activeSessionId, previousSessionId) }
        let recovery = Recovery(queue: store.database, store: store)
        let decision = (try? recovery.decideLaunch()) ?? .fresh(previous: nil)
        let resolved: (SessionID, SessionID?)
        switch decision {
        case .resume(let id):
            resolved = (id, nil)
        case .fresh(let previous):
            resolved = ((try? store.startSession()) ?? UUID().uuidString, previous)
        }
        activeSessionId = resolved.0
        previousSessionId = resolved.1
        return resolved
    }

    func refreshMind() {
        guard let chatModel else { return }
        Task { await chatModel.loadMind() }
    }

    /// scenePhase .background: cierre limpio de la sesión activa.
    func markCleanShutdown() {
        guard let store, let activeSessionId else { return }
        try? store.markCleanShutdown(activeSessionId)
    }

    /// Fallback foreground (§5.4): si pasaron >48h sin ciclo completo, se corre al
    /// abrir la app (best-effort, no bloqueante).
    private func runForegroundFallbackIfNeeded(_ consolidator: Consolidator) async {
        let last = await consolidator.lastCycleAt()
        guard sleepScheduler.shouldRunForegroundFallback(lastCycleAt: last) else { return }
        let scheduler = sleepScheduler
        let selfModel = self.selfModel
        await sleepActivity.start(selfName: await selfModel?.name() ?? "Anima")
        Task.detached { [sleepActivity] in
            let completed = await scheduler.runResumable(consolidator)
            await sleepActivity.finish(completed: completed, night: await selfModel?.cycles() ?? 0)
            await AppModel.live.publishWidgets()
        }
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
                // Lanzamiento en background: cablea el harness si la escena no lo hizo.
                await AppModel.live.ensureBootstrapped()
                let success = await AppModel.shared.run(isExpired: { expired.value })
                // Noche nueva: el widget muestra el número y la plasticidad al día.
                await AppModel.live.publishWidgets()
                task.setTaskCompleted(success: success)
            }
        }
        #endif
    }

    /// Registro del BGAppRefreshTask del pulso (§5.8). Siempre completa el task.
    static func registerPulseTask() {
        #if os(iOS)
        PulseScheduler().register { task in
            nonisolated(unsafe) let task = task
            let work = Task { @MainActor in
                await AppModel.live.ensureBootstrapped()
                let outcome = await AppModel.live.runBackgroundPulse()
                PulseScheduler().submit()
                task.setTaskCompleted(success: outcome != nil)
            }
            task.expirationHandler = { work.cancel() }
        }
        #endif
    }

    /// El pulso en background: recordatorios vencidos → pulso del deseo →
    /// Intentions como notificación local. nil si el harness no está cableado.
    func runBackgroundPulse() async -> PulseRunner.Outcome? {
        guard let store, reconciler != nil else { return nil }
        await applyWidgetActions()
        let (sessionId, _) = resolveSession(store)
        let runner = PulseRunner(reconciler: reconciler, engine: desireEngine, scheduler: proactiveScheduler)
        let outcome = await runner.run(sessionId: sessionId)
        chatModel?.appendProactive(outcome.delivered)
        return outcome
    }

    /// Acción de una notificación (Hecho / En 1 hora / Sí, avancé / Hoy no): corre
    /// sin abrir la app, sobre el harness ya cableado.
    func handleNotificationAction(_ action: ProactiveNotificationAction) async {
        await ensureBootstrapped(configFetchTimeout: RemoteConfigFetch.notificationActionTimeout)
        let handler = ProactiveActionHandler(reminders: reminderStore, otherModel: otherModel,
                                             scheduler: proactiveScheduler)
        await handler.handle(action)
        await goalsModel?.refresh()
        await settingsModel?.notifications?.refresh()
    }

    static func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    func schedulePulse() {
        #if os(iOS)
        PulseScheduler().submit()
        #endif
    }

    /// ¿iOS lanzó el proceso sin UI (BGTask / acción de notificación)?
    static var launchedInBackground: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .background
        #else
        return false
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
    /// el pipeline puro ya viven en AnimaKit. Las de gafas se declaran SIEMPRE
    /// (prefijo cacheado estable, doc 05 §5); sin gafas responden "no conectadas".
    static func tools(glasses: LateBoundGlassesHost, reminders: AnimaReminderStore?, otherModel: OtherModel?,
                      proactive: ProactiveScheduler?) -> [any SensorimotorTool] {
        var tools: [any SensorimotorTool] = [
            CalendarTool(),
            RemindersTool(),
            NotesTool(),
            PhoneContextTool(),
            CameraTool(),
            AudioTool(),
            GlassesShowTool(host: glasses),
            GlassesCameraTool(host: glasses),
        ]
        if let reminders {
            tools.append(AnimaRemindersTool(store: reminders, onChange: { await proactive?.sync() }))
        }
        if let otherModel {
            tools.append(GoalsTool(otherModel: otherModel, onChange: { await proactive?.sync() }))
        }
        return tools
    }

    // MARK: - Gafas (track G)

    /// SDK real en device/simulador; runtime nulo en `--uitest` (sin BT ni Meta AI).
    static func makeGlassesRuntime() -> any GlassesRuntime {
        if UITestMode.isActive { return AbsentGlassesRuntime() }
        #if canImport(MWDATCore) && canImport(MWDATDisplay)
        return DATGlassesRuntime()
        #else
        return AbsentGlassesRuntime()
        #endif
    }

    /// Voice invocations: SDK real fuera de `--uitest` (sin gafas ni Meta AI ahí).
    static func makeVoiceInvocationsPort() -> (any VoiceInvocationsPort)? {
        if UITestMode.isActive { return nil }
        #if canImport(MWDATCore)
        return VoiceInvocationsController()
        #else
        return nil
        #endif
    }

    /// Mic del composer: el pipeline de voz de las gafas forzado al micrófono
    /// del TELÉFONO (nunca HFP). `--uitest`: voz guionada con transcript fijo.
    static func makePhoneVoice() -> (any VoiceCapturePort)? {
        if UITestMode.isActive { return UITestScriptedVoice() }
        #if os(iOS)
        return GlassesVoiceCapture(audio: PhoneMicAudioSession(SystemAudioSession()), detector: .phoneDictation)
        #else
        return nil
        #endif
    }

    /// G1: la superficie HUD sobre el mismo loop y la MISMA sesión que el chat.
    private func wireGlassesSurface(loop: AgentLoop, sessionId: SessionID) async {
        glassesSurface?.stop()
        glassesSurface = nil
        glassesHost.bind(nil, confirm: nil)
        guard let glassesBody else { return }
        let voice: any VoiceCapturePort
        let speech: any SpeechOutputPort
        #if os(iOS)
        if UITestMode.isActive {
            voice = SilentVoice(); speech = SilentVoice()
        } else {
            voice = GlassesVoiceCapture(diagnostics: .shared); speech = GlassesSpeaker()
        }
        #else
        voice = SilentVoice(); speech = SilentVoice()
        #endif
        let surface = GlassesHUDSurface(
            body: glassesBody, activation: glassesActivation, runner: loop, sessionId: sessionId,
            voice: voice, speech: speech, router: surfaceRouter,
            openPhone: { [weak self] turn in self?.handoffToPhone(turn: turn) })
        glassesSurface = surface
        glassesHost.bind(surface, confirm: { [weak surface] request in
            await surface?.confirmCamera(request) ?? false
        })
        await surface.start()
    }

    /// "Ver en el teléfono" desde las gafas: notificación con el deep link (el
    /// teléfono suele estar en el bolsillo) y, si la app está al frente, salta ya.
    private func handoffToPhone(turn: UUID?) {
        let link = AnimaDeepLink.chat(turn: turn)
        HandoffNotifications.post(link)
        open(link)
    }

    private func open(_ link: AnimaDeepLink) {
        switch link {
        case .chat(let turn):
            guard deferUntilReady(link) else { return }
            selectedTab = .chat
            chatModel?.focus(turn: turn)
        case .glasses:
            guard let glassesActivation else { return }
            Task { await glassesActivation.userRequested() }
        case .reminder(let id):
            guard deferUntilReady(link) else { return }
            selectedTab = .chat
            Task {
                await reconcileProactive()
                chatModel?.focus(.reminder(id: id))
            }
        case .goal(let id):
            guard deferUntilReady(link) else { return }
            selectedTab = .chat
            Task {
                if let prompt = await reconciler?.checkInPrompt(goalId: id, sessionId: activeSessionId) {
                    chatModel?.appendProactive([prompt])
                }
                chatModel?.focus(.checkIn(goalId: id))
            }
        case .intention(let id):
            guard deferUntilReady(link) else { return }
            selectedTab = .chat
            Task {
                await chatModel?.loadProactiveIntentions()
                chatModel?.focus(.intention(id: id))
            }
        case .talk:
            guard deferUntilReady(link) else { return }
            selectedTab = .chat
            chatModel?.startVoice()
        case .reminders:
            guard deferUntilReady(link) else { return }
            selectedTab = .reminders
            Task { await remindersModel?.refresh() }
        case .goals(let id):
            guard deferUntilReady(link) else { return }
            selectedTab = .goals
            if let id { goalsModel?.focus(goalId: id) }
        }
    }

    /// false (y lo guarda) si el chat aún no está cableado: el cableado lo abre
    /// al terminar. Arranca el cableado si nadie lo hizo (el tap al push puede
    /// llegar antes que la escena).
    private func deferUntilReady(_ link: AnimaDeepLink) -> Bool {
        guard phase == .ready, chatModel != nil else {
            pendingLink = link
            Task { await ensureBootstrapped() }
            return false
        }
        return true
    }

    /// `anima://`: deep link propio (handoff) o callback de Meta AI (registro DAT).
    func handleOpenURL(_ url: URL) {
        if let link = AnimaDeepLink.parse(url) {
            open(link)
            return
        }
        guard let glassesBody else { return }
        Task { _ = try? await glassesBody.handleURL(url) }
    }

    func glassesForeground(_ active: Bool) {
        guard let glassesActivation else { return }
        Task { await glassesActivation.setForeground(active) }
    }

    private static func skillsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(UITestMode.isActive ? UITestMode.skillsDirectoryName : "skills",
                                          isDirectory: true)
    }

    /// `--uitest`: su base aislada en Documents. Dueño: la del App Group, con la
    /// mudanza única y verificada desde Documents (DatabaseRelocation); si algo
    /// falla, la de Documents intacta (se reintenta en el próximo arranque).
    private static func databasePath() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if UITestMode.isActive { return dir.appendingPathComponent(UITestMode.databaseName).path }
        let relocation = DatabaseRelocation(legacyURL: dir.appendingPathComponent(DatabaseRelocation.fileName),
                                            groupDirectory: AppGroup.databaseDirectory(),
                                            protect: { protect(path: $0.path) })
        return relocation.resolve().path
    }

    /// Protección del .sqlite alineada con el token del Keychain (AfterFirstUnlock):
    /// Complete impediría que el BGTask nocturno abra la DB con el teléfono bloqueado (§8).
    nonisolated private static func protect(path: String) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
    }
}

/// Tabs del shell (selección programática para el deep link del handoff).
typealias AppTab = ShellTab

/// Enrutado del shell (handoff): splash → (landing → onboarding) | chat.
/// El TabView existente es el destino post-onboarding.
struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            switch app.phase {
            case .loading:
                SplashView()
                    .transition(.opacity)
            case .misconfigured(let reason):
                misconfigured(reason)
            case .needsToken, .ready:
                if needsFirstRun {
                    FirstRunContainer(app: app)
                        .transition(.opacity)
                } else if app.phase == .ready, app.chatModel != nil {
                    shellTabs
                        .transition(.opacity)
                } else {
                    // Token presente pero el cableado aún resuelve.
                    SplashView()
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: Theme.Motion.enter), value: app.phase)
        .animation(.easeOut(duration: Theme.Motion.enter), value: needsFirstRun)
        .preferredColorScheme(.dark)
    }

    /// Landing/onboarding si no hay token o la mente no ha nacido (Birth).
    private var needsFirstRun: Bool {
        FirstRunRouter.destination(
            hasToken: app.phase != .needsToken,
            hasOnboarded: app.onboarded) == .landing
    }

    private var shellTabs: some View {
        TabView(selection: $app.selectedTab) {
            if let chat = app.chatModel {
                ChatView(model: chat)
                    .confirmationOverlay(app.confirmation)
                    .tabItem { Label(AppTab.chat.title, systemImage: "bubble.left").accessibilityIdentifier("tab.chat") }
                    .tag(AppTab.chat)
            }
            if let memory = app.memoryModel {
                MemoryBrowserView(model: memory)
                    .tabItem { Label(AppTab.memory.title, systemImage: "brain").accessibilityIdentifier("tab.memory") }
                    .tag(AppTab.memory)
            }
            if let goals = app.goalsModel {
                GoalsView(model: goals)
                    .tabItem { Label(AppTab.goals.title, systemImage: "target").accessibilityIdentifier("tab.goals") }
                    .tag(AppTab.goals)
            }
            if let reminders = app.remindersModel {
                RemindersView(model: reminders)
                    .tabItem { Label(AppTab.reminders.title, systemImage: "bell").accessibilityIdentifier("tab.reminders") }
                    .tag(AppTab.reminders)
            }
            if let settings = app.settingsModel {
                SettingsView(model: settings)
                    .tabItem { Label(AppTab.settings.title, systemImage: "gearshape").accessibilityIdentifier("tab.settings") }
                    .tag(AppTab.settings)
                    .badge(app.pendingApprovals)
            }
        }
        .tint(Theme.Colors.accent)
    }

    private func misconfigured(_ reason: String) -> some View {
        VStack(spacing: Theme.Space.stack) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
            Text(reason)
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.screenInset)
    }
}

/// Primer arranque: landing (intro) → flujo de 7 pasos. En "Repetir onboarding"
/// entra directo al flujo (la mente ya nació).
struct FirstRunContainer: View {
    @ObservedObject var app: AppModel
    @State private var onboardingModel: OnboardingViewModel?

    var body: some View {
        Group {
            if let model = onboardingModel {
                OnboardingFlowView(model: model) {
                    onboardingModel = nil
                    app.exitOnboardingFlow()
                }
            } else {
                LandingView {
                    onboardingModel = app.makeOnboardingModel()
                }
            }
        }
        .onAppear { enterFlowIfReplaying(app.replayingOnboarding) }
        .onChange(of: app.replayingOnboarding) { _, replaying in
            enterFlowIfReplaying(replaying)
        }
    }

    private func enterFlowIfReplaying(_ replaying: Bool) {
        if replaying, onboardingModel == nil {
            onboardingModel = app.makeOnboardingModel()
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
    /// Alto medido del contenido: el sheet abraza lo que muestra (sin área vacía).
    @State private var height: CGFloat = 320

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { center.pending != nil },
            set: { if !$0 { center.resolve(false) } }
        )) {
            if let request = center.pending {
                ConfirmationSheet(request: request) { center.resolve($0) }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .presentationDetents([.height(height)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.Colors.surface)
            }
        }
    }
}
