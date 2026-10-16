// SheetGrabber.swift — el indicador de arrastre de TODO bottom sheet (campo
// 2026-10-16: "la línea de arriba se ve muy cerca del borde"). El de sistema
// (.presentationDragIndicator) queda a ~5 pt del borde y en iOS 26, con el radio
// grande del sheet, se ve pegado. Este es la misma cápsula de 36 × 5 pt, a 10 pt
// del borde, en el color del Theme; va encima del contenido, sin cambiar el alto
// medido de los sheets que abrazan su contenido.

#if canImport(SwiftUI)
import SwiftUI

public struct SheetGrabber: View {
    static let size = CGSize(width: 36, height: 5)
    static let topInset: CGFloat = Theme.Space.unit * 2.5

    public init() {}

    public var body: some View {
        Capsule()
            .fill(Theme.Colors.textFaint.opacity(0.6))
            .frame(width: Self.size.width, height: Self.size.height)
            .padding(.top, Self.topInset)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Cromo común de los bottom sheets: fondo del Theme e indicador de arrastre
    /// propio (el de sistema se oculta para que no haya dos).
    public func animaSheet(background: Color = Theme.Colors.surface) -> some View {
        self
            .overlay(alignment: .top) { SheetGrabber().allowsHitTesting(false) }
            .presentationDragIndicator(.hidden)
            .presentationBackground(background)
    }
}
#endif
