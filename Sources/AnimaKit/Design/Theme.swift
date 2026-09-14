// Theme.swift — tokens del sistema de diseño de Anima como constantes SwiftUI.
// Fuente de verdad: Design/design-tokens.json (handoff de diseño, dark-only).
// Regla del sistema: un solo acento, siempre línea o glow, nunca fill;
// sin rojo ni verde — el estado lo cargan el peso, la opacidad y el copy.

import SwiftUI

public enum Theme {

    // MARK: - Color (dark only)

    public enum Colors {
        public static let bg = Color(hex: 0x1D2D3D)
        public static let surface = Color(hex: 0x243849)
        public static let border = Color(hex: 0x2C455D)
        public static let text = Color(hex: 0xF5F5F8)
        public static let textMuted = Color(hex: 0xB7C4D2)
        public static let textFaint = Color(hex: 0x8AA0B6)
        public static let accent = Color(hex: 0x94BCE3)
        public static let accentText = Color(hex: 0xD6EBFF)
        public static let tint = Color(hex: 0x94BCE3).opacity(0.12)
        public static let scrim = Color.black.opacity(0.45)

        /// Paleta del HUD (gafas) — tinta sobre vidrio.
        public enum HUD {
            public static let ink = Color(hex: 0xE8F3FF)
            public static let inkMuted = Color(hex: 0xB7D3EE)
            public static let halo = Color(hex: 0x94BCE3).opacity(0.6)
        }
    }

    // MARK: - Tipografía (SF Pro del sistema, pesos 400/500)

    public enum Type_ {
        public static let hero = Font.system(size: 28, weight: .medium)
        public static let screenTitle = Font.system(size: 24, weight: .medium)
        public static let cardTitle = Font.system(size: 16, weight: .medium)
        public static let body = Font.system(size: 15, weight: .regular)
        public static let secondary = Font.system(size: 13, weight: .regular)
        public static let meta = Font.system(size: 12, weight: .regular)
        /// Uppercase, tracking 0.06em — aplicar `.textCase(.uppercase)` + `.kerning(0.66)`.
        public static let label = Font.system(size: 11, weight: .regular)
        public static let tab = Font.system(size: 10, weight: .regular)

        /// Donde aparezca plasticidad o dinero: `.monospacedDigit()`.
        public static func tabular(_ font: Font) -> Font { font.monospacedDigit() }
    }

    // MARK: - Espaciado y forma

    public enum Space {
        public static let unit: CGFloat = 4
        public static let screenInset: CGFloat = 20
        public static let stack: CGFloat = 12
        public static let cardPad: CGFloat = 14
        public static let sectionGap: CGFloat = 20
        public static let tabBarBottom: CGFloat = 30
    }

    public enum Radius {
        public static let control: CGFloat = 8
        public static let card: CGFloat = 8
        public static let chip: CGFloat = 6
        public static let sheet: CGFloat = 16
    }

    public enum Stroke {
        public static let hairline: CGFloat = 1
        public static let icon: CGFloat = 1.5
        public static let mark: CGFloat = 2.4
    }

    public static let minHitTarget: CGFloat = 44

    // MARK: - Motion (duraciones en segundos)

    public enum Motion {
        public static let enter: TimeInterval = 0.300      // ease-out, rise 6px
        public static let sheet: TimeInterval = 0.250      // ease-out
        public static let streamCaret: TimeInterval = 1.0  // steps(1)
        public static let thinkingPulse: TimeInterval = 1.4 // ease-in-out, opacity 0.35→1
        public static let voiceWave: TimeInterval = 0.9    // stagger 0.15
        public static let voiceWaveStagger: TimeInterval = 0.15
        public static let plasticity: TimeInterval = 0.600 // ring/amplitud al cambiar ciclos
    }

    // MARK: - La marca "Breath"
    // Onda cuya amplitud respira con la plasticidad de la mente:
    // A = 4 + 14·p  →  18 al nacer (p=1), ~4.7 en madurez (p=0.05).

    public enum Mark {
        public static let viewBox: CGFloat = 96
        public static let dotRadius: CGFloat = 2.8

        public static func amplitude(plasticity p: Double) -> CGFloat {
            CGFloat(4 + 14 * p)
        }

        /// Opacidad del glow radial: 0.2 + 0.4·p.
        public static func glowOpacity(plasticity p: Double) -> Double {
            0.2 + 0.4 * p
        }
    }
}

// MARK: - Helpers

extension Color {
    /// Color desde hex RGB de 24 bits (tokens del design system).
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
