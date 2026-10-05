// ImageViewer.swift — visor fullscreen de fotos del chat (campo batch 3, FIX G).
// Fondo negro, imagen completa (decode async con spinner), zoom con pinch y
// doble-tap, pan cuando hay zoom, X arriba-derecha (patrón overlay del design
// system) y swipe-down para cerrar.

#if canImport(SwiftUI)
import SwiftUI

struct ImageViewer: View {
    let data: Data
    let onClose: () -> Void

    @State private var image: CGImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dismissDrag: CGFloat = 0

    static let maxScale: CGFloat = 4
    static let doubleTapScale: CGFloat = 2.5
    static let dismissThreshold: CGFloat = 120

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(0.6, Double(abs(dismissDrag) / 400)))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            NavCloseButton("imageViewer", action: onClose)
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
        .task {
            image = await ImageLoader.load(data, maxPixel: nil)
            failed = image == nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.imageViewer")
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + dismissDrag)
                .gesture(magnify.simultaneously(with: drag))
                .onTapGesture(count: 2) { toggleZoom() }
                .accessibilityLabel("Foto")
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("chat.imageViewer.image")
        } else if failed {
            Text("No se pudo abrir la foto.")
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)
        } else {
            ProgressView()
                .tint(Theme.Colors.accent)
                .accessibilityIdentifier("chat.imageViewer.loading")
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(Self.maxScale, max(1, lastScale * value.magnification))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    /// Con zoom: pan. Sin zoom: arrastrar hacia abajo cierra.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else {
                    dismissDrag = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if value.translation.height > Self.dismissThreshold
                            || value.predictedEndTranslation.height > Self.dismissThreshold * 2 {
                    onClose()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dismissDrag = 0 }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.25)) {
            if scale > 1 {
                resetZoom()
            } else {
                scale = Self.doubleTapScale
                lastScale = scale
            }
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
#endif
