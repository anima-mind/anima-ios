// NavCloseButton.swift — salida visible de overlays y sheets (patrón del design
// system: X de 44 pt arriba a la derecha). Identifier `nav.close.<pantalla>`.

#if canImport(SwiftUI)
import SwiftUI

public struct NavCloseButton: View {
    let screen: String
    let action: () -> Void

    public init(_ screen: String, action: @escaping () -> Void) {
        self.screen = screen
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cerrar")
        .accessibilityIdentifier("nav.close.\(screen)")
    }
}
#endif
