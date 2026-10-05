// SkillsSettingsSection.swift — Ajustes → Skills (§5.7, campo batch 3 FIX A):
// explicador + "Ver ejemplo", la lista de skills del dir (Documents/skills) con
// su nivel aprendida → practicada (3 éxitos seguidos) → automatizada (5) y su
// toggle, "Enséñame algo" (taller conversacional), importar desde Archivos y
// tap → editar/eliminar en el mismo taller. Las seeds también son del dueño.

#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class SkillsViewModel: ObservableObject {
    @Published public private(set) var rows: [SkillOverview] = []
    @Published public var notice: String?
    /// Nombre del self para el explicador ("Betty las consulta…").
    @Published public var selfName = Birth.seed.name
    private let engine: SkillEngine
    /// Escritura de skills (Documents/skills). nil ⇒ solo lectura (tests viejos).
    public let library: SkillLibrary?
    /// Markdown de una seed para "Ver ejemplo" (lo inyecta el shell desde el bundle).
    public var exampleMarkdown: String?
    /// Fábrica de la sesión efímera del taller sobre el córtex activo (la
    /// cablea el shell cuando hay selector). nil ⇒ "Enséñame algo" deshabilitado.
    public var makeSession: ((SkillWorkshopMode) throws -> SkillWorkshopSession)?
    /// Mic del composer del taller (el mismo pipeline de voz del chat).
    public var makeVoice: (() -> (any VoiceCapturePort)?)?

    public init(engine: SkillEngine, library: SkillLibrary? = nil) {
        self.engine = engine
        self.library = library
    }

    /// Relee el dir (hot-reload por mtime en el SkillStore) y el estado de práctica.
    public func load() {
        Task { await reload() }
    }

    public func reload() async {
        rows = await engine.overview()
    }

    public func setEnabled(_ name: String, _ enabled: Bool) {
        Task {
            await engine.setDisabled(name, !enabled)
            rows = await engine.overview()
        }
    }

    /// Resumen vivo para la fila del hub: "3 aprendidas · 1 automatizada".
    public var summaryLine: String {
        guard !rows.isEmpty else { return "Sin skills todavía" }
        let learned = rows.count == 1 ? "1 aprendida" : "\(rows.count) aprendidas"
        let auto = rows.filter(\.automatized).count
        return "\(learned) · \(auto == 1 ? "1 automatizada" : "\(auto) automatizadas")"
    }

    public var canTeach: Bool { makeSession != nil && library != nil }

    /// El taller para crear (o editar la skill `name`).
    public func workshop(editing name: String? = nil) -> SkillWorkshopViewModel? {
        guard let library else { return nil }
        let mode: SkillWorkshopMode
        if let name {
            guard let markdown = library.markdown(named: name) else { return nil }
            mode = .edit(name: name, markdown: markdown)
        } else {
            mode = .create
        }
        let practice = name.flatMap { n in rows.first { $0.name == n } }?.totalSuccess ?? 0
        let model = SkillWorkshopViewModel(mode: mode, library: library, practiceSuccesses: practice,
                                           makeSession: makeSession)
        model.voice = makeVoice?()
        model.onChanged = { [weak self] in
            guard let self else { return }
            Task { await self.reload() }
        }
        return model
    }

    /// "Importar desde Archivos": valida/envuelve el front-matter y copia.
    public func importFile(_ url: URL) async {
        guard let library else { return }
        do {
            let skill = try library.importFile(url)
            notice = "Importada: \(skill.name)."
        } catch {
            notice = "No se pudo importar: \(error.localizedDescription)"
        }
        await reload()
    }

    public static func title(_ level: SkillLevel) -> String {
        switch level {
        case .learned: return "aprendida"
        case .practiced: return "practicada"
        case .automatized: return "automatizada"
        }
    }

    public static func status(_ row: SkillOverview) -> String {
        let successes = row.totalSuccess == 1 ? "1 éxito" : "\(row.totalSuccess) éxitos"
        return "\(title(row.level)) · \(successes)"
    }
}

/// Ajustes → Skills (sub-pantalla del hub).
struct SkillsSettingsScreen: View {
    @ObservedObject var model: SkillsViewModel
    @State private var showExample = false
    @State private var importing = false
    @State private var workshop: SkillWorkshopViewModel?

    var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                    explainer
                    actions
                    list
                    Text("Con 3 éxitos seguidos pasa a practicada; con 5, a automatizada: corre sola sus lecturas y las escrituras siempre te piden ok. Un fallo la devuelve a aprendida. La práctica se guarda por nombre: renombrar una skill la vuelve nueva.")
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayModeInline()
        .onAppear { model.load() }
        .sheet(isPresented: $showExample) {
            SkillExampleSheet(markdown: model.exampleMarkdown ?? "")
                .presentationDetents([.large])
                .presentationBackground(Theme.Colors.bg)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText, .text]) { result in
            if case .success(let url) = result { Task { await model.importFile(url) } }
        }
        .navigationDestination(item: $workshop) { workshop in
            SkillWorkshopView(model: workshop)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Las skills son conocimiento: cómo hacer algo, en markdown. \(model.selfName) las consulta cuando un pedido encaja y, con la práctica, las automatiza.")
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("skills.explainer")
            if model.exampleMarkdown != nil {
                Button("Ver ejemplo") { showExample = true }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .accessibilityIdentifier("skills.example")
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            actionRow("Enséñame algo", detail: "Una conversación corta y ella redacta la skill",
                      glyph: "sparkles", id: "skills.new", enabled: model.canTeach) {
                workshop = model.workshop()
            }
            Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
            actionRow("Importar desde Archivos", detail: ".md o .txt", glyph: "square.and.arrow.down",
                      id: "skills.import", enabled: model.library != nil) {
                importing = true
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
        .overlay(alignment: .bottomLeading) {
            if let notice = model.notice {
                Text(notice)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.accentText)
                    .offset(y: 22)
                    .accessibilityIdentifier("skills.notice")
            }
        }
    }

    private func actionRow(_ title: String, detail: String, glyph: String, id: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.stack) {
                Image(systemName: glyph)
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(enabled ? Theme.Colors.accent : Theme.Colors.textFaint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Type_.body)
                        .foregroundStyle(enabled ? Theme.Colors.accentText : Theme.Colors.textFaint)
                    Text(detail)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Theme.Colors.textFaint)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, Theme.Space.cardPad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Tus skills")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
                .padding(.top, model.notice == nil ? 0 : 16)
            if model.rows.isEmpty {
                Text("Sin skills todavía.")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
                        }
                        skillRow(row)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            }
        }
    }

    private static func levelColor(_ level: SkillLevel) -> Color {
        switch level {
        case .learned: return Theme.Colors.textFaint
        case .practiced: return Theme.Colors.textMuted
        case .automatized: return Theme.Colors.accentText
        }
    }

    /// Tap en el nombre → taller en modo editar; el toggle a la derecha.
    private func skillRow(_ row: SkillOverview) -> some View {
        HStack(spacing: Theme.Space.stack) {
            Button {
                workshop = model.workshop(editing: row.name)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(Theme.Type_.body)
                            .foregroundStyle(row.disabled ? Theme.Colors.textFaint : Theme.Colors.text)
                        HStack(spacing: 4) {
                            if row.automatized {
                                Image(systemName: "bolt")
                                    .font(.system(size: 10, weight: .light))
                            }
                            Text(SkillsViewModel.status(row))
                        }
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Self.levelColor(row.level))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(Theme.Colors.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canTeach)
            .accessibilityIdentifier("skills.row.\(row.name)")
            Toggle("", isOn: Binding(get: { !row.disabled }, set: { model.setEnabled(row.name, $0) }))
                .labelsHidden()
                .tint(Theme.Colors.accent)
                .accessibilityLabel("Activa \(row.name)")
                .accessibilityIdentifier("skills.toggle.\(row.name)")
        }
        .frame(minHeight: 52)
        .padding(.horizontal, Theme.Space.cardPad)
        .padding(.vertical, 4)
    }
}

/// "Ver ejemplo": el markdown de una seed, solo lectura y monoespaciado.
struct SkillExampleSheet: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.Colors.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    Text("EJEMPLO DE SKILL")
                        .font(Theme.Type_.label)
                        .kerning(0.66)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text("Arriba, entre ---, el front-matter: name, when (cuándo usarla) y opcionalmente los pasos que puede correr sola. Abajo, en prosa, el cómo.")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    SkillMarkdownCard(markdown: markdown)
                }
                .padding(Theme.Space.screenInset)
                .padding(.top, Theme.Space.sectionGap)
            }
            NavCloseButton("skillExample") { dismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.exampleSheet")
    }
}

/// Markdown de una skill: monoespaciado sobre surface (accent jamás de relleno).
struct SkillMarkdownCard: View {
    let markdown: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(markdown)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.Colors.text)
                .textSelection(.enabled)
                .padding(Theme.Space.cardPad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
    }
}

#endif
