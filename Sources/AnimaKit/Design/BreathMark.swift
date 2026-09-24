// BreathMark.swift — la marca "Breath": la cara de Anima (handoff §05).
// Dos ondas que suben hacia una A sobre una línea en reposo, con un punto
// encendido donde se cruzan. Amplitud = 4 + 14·p, así el ícono, el intro y el
// Mind sheet son un mismo dibujo a distintas edades. Nunca gira ni rebota:
// respira (4 s), escucha (1.1 s), habla (0.6 s) o piensa (glow 1.6 s).

#if canImport(SwiftUI)
import SwiftUI

/// Fase de animación del mark (handoff §Conversation mode + launch).
public enum BreathPhase: Sendable, Equatable {
    case idle          // estático, sin animación
    case breathing     // launch/intro: la onda respira en ciclo de 4 s
    case listening     // la onda respira a 1.1 s + glow
    case speaking      // la onda se mueve con la voz a 0.6 s
    case thinking      // la onda quieta, el glow pulsa a 1.6 s
}

/// La onda del mark, escalada del viewBox 96 del SVG del handoff:
/// `M18 50c8 0 8 A 16 A s8 -2A 16 -2A s8 2A 16 2A s8 -A 12 -A`
/// (con A = 18 se obtiene el path literal del board).
public struct BreathWaveShape: Shape {
    /// Amplitud en unidades del viewBox (Theme.Mark.amplitude(plasticity:)).
    public var amplitude: CGFloat

    public init(amplitude: CGFloat) {
        self.amplitude = amplitude
    }

    public var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / Theme.Mark.viewBox
        let a = amplitude
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        p.move(to: pt(18, 50))
        p.addCurve(to: pt(34, 50 + a), control1: pt(26, 50), control2: pt(26, 50 + a))
        p.addCurve(to: pt(50, 50 - a), control1: pt(42, 50 + a), control2: pt(42, 50 - a))
        p.addCurve(to: pt(66, 50 + a), control1: pt(58, 50 - a), control2: pt(58, 50 + a))
        p.addCurve(to: pt(78, 50), control1: pt(74, 50 + a), control2: pt(74, 50))
        return p
    }
}

/// Fondo radial del handoff (2c455d → 101b26, centro 50%/60%). Se usa en el
/// splash, el intro y el modo conversación.
public struct RadialGround: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [Theme.Colors.groundInner, Theme.Colors.groundOuter],
                center: UnitPoint(x: 0.5, y: 0.6),
                startRadius: 0,
                endRadius: max(geo.size.width, geo.size.height) * 0.85)
        }
        .ignoresSafeArea()
    }
}

/// El mark completo: glow elíptico detrás, onda con gradiente, línea base y
/// punto central. `p` gobierna la amplitud (4 + 14·p) y la opacidad del glow.
public struct BreathMark: View {
    private let size: CGFloat
    private let p: Double
    private let phase: BreathPhase

    public init(size: CGFloat, p: Double = 1.0, phase: BreathPhase = .idle) {
        self.size = size
        self.p = p
        self.phase = phase
    }

    public var body: some View {
        if phase == .idle {
            mark(waveScale: 1, glowPulse: 1)
                .frame(width: size, height: size)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                mark(waveScale: waveScale(at: t), glowPulse: glowPulse(at: t))
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: - Curvas por fase

    /// Oscilador 0→1→0 tipo ease-in-out (coseno) con el período dado.
    private func osc(_ t: TimeInterval, period: TimeInterval) -> Double {
        0.5 - 0.5 * cos(2 * .pi * t / period)
    }

    /// Escala vertical de la onda (an-breathe: scaleY 0.45 ↔ 1).
    private func waveScale(at t: TimeInterval) -> Double {
        switch phase {
        case .idle: return 1
        case .breathing: return 0.45 + 0.55 * osc(t, period: Theme.Mark.Phase.breathing)
        case .listening: return 0.45 + 0.55 * osc(t, period: Theme.Mark.Phase.listening)
        case .speaking: return 0.45 + 0.55 * osc(t, period: Theme.Mark.Phase.speaking)
        case .thinking: return 1  // la onda quieta; solo pulsa el glow
        }
    }

    /// Pulso del glow (an-glow: opacidad 0.35 ↔ 0.9).
    private func glowPulse(at t: TimeInterval) -> Double {
        switch phase {
        case .idle: return 1
        case .breathing: return 0.35 + 0.55 * osc(t, period: Theme.Mark.Phase.breathing)
        case .listening: return 0.35 + 0.55 * osc(t, period: Theme.Mark.Phase.listening)
        case .speaking: return 0.9
        case .thinking: return 0.35 + 0.55 * osc(t, period: Theme.Mark.Phase.thinkingGlow)
        }
    }

    // MARK: - Dibujo

    private func mark(waveScale: Double, glowPulse: Double) -> some View {
        let unit = size / Theme.Mark.viewBox
        let amplitude = Theme.Mark.amplitude(plasticity: p) * waveScale
        return ZStack {
            // Glow elíptico (hGl): radial accent 0.55 → 0, rx 30 ry 14, cy 50.
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Theme.Colors.accent.opacity(0.55), Theme.Colors.accent.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 30 * unit))
                .frame(width: 60 * unit, height: 28 * unit)
                .position(x: 48 * unit, y: 50 * unit)
                .opacity(Theme.Mark.glowOpacity(plasticity: p) / 0.6 * glowPulse)

            // Línea base (M18 50h60, accent al 50%).
            Path { path in
                path.move(to: CGPoint(x: 18 * unit, y: 50 * unit))
                path.addLine(to: CGPoint(x: 78 * unit, y: 50 * unit))
            }
            .stroke(Theme.Colors.accent.opacity(0.5), lineWidth: max(1, unit))

            // La onda (hSt: accent .15 → accentText → accent .15).
            BreathWaveShape(amplitude: amplitude)
                .stroke(
                    LinearGradient(
                        colors: [Theme.Colors.accent.opacity(0.15),
                                 Theme.Colors.accentText,
                                 Theme.Colors.accent.opacity(0.15)],
                        startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 3 * unit, lineCap: .round))

            // El punto donde las ondas se cruzan (r = 3, texto pleno).
            Circle()
                .fill(Theme.Colors.text)
                .frame(width: 6 * unit, height: 6 * unit)
                .position(x: 48 * unit, y: 50 * unit)
        }
        .frame(width: size, height: size)
    }
}
#endif
