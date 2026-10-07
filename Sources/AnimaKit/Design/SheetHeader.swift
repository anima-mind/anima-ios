// SheetHeader.swift — la primera fila de TODO bottom sheet (campo batch 8 #4):
// título a la izquierda y la X a la derecha, DENTRO del padding del sheet y
// alineada con la primera fila de contenido (antes flotaba arriba a la derecha,
// pegada al borde y al drag indicator). Área táctil de 44 pt; el glifo queda
// alineado al borde del contenido. Identifier `nav.close.<pantalla>`.

#if canImport(SwiftUI)
import SwiftUI

public struct SheetHeader: View {
    public enum Style { case label, title }

    let title: String?
    let style: Style
    let screen: String
    let action: () -> Void

    /// Lo que la caja de 44 pt sobresale del glifo a cada lado: se devuelve
    /// al padding para que el glifo (no la caja) toque el borde del contenido.
    static let glyphInset: CGFloat = (Theme.minHitTarget - 15) / 2

    public init(_ title: String? = nil, style: Style = .label, screen: String, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.screen = screen
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.stack) {
            if let title {
                switch style {
                case .label:
                    Text(title)
                        .font(Theme.Type_.label)
                        .textCase(.uppercase)
                        .kerning(0.66)
                        .foregroundStyle(Theme.Colors.textMuted)
                case .title:
                    Text(title)
                        .font(Theme.Type_.heading2)
                        .foregroundStyle(Theme.Colors.text)
                }
            }
            Spacer(minLength: 0)
            NavCloseButton(screen, action: action)
                .padding(.trailing, -Self.glyphInset)
        }
        .frame(minHeight: Theme.minHitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.header.\(screen)")
    }
}
#endif
