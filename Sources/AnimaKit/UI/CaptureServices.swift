// CaptureServices.swift — captura iniciada por el dueño (§5.7, §8). La cámara y el
// micrófono solo capturan por acción explícita del dueño; la lógica pura (downscale,
// prefijo de transcript) vive en AnimaKit (ImageDownscaler, AudioTool). Todo iOS-only:
// #if os(iOS) para que `swift test` en macOS siga verde. Pendiente de verificación
// en dispositivo real (permisos TCC, cámara, calidad es-CO del reconocimiento).

#if os(iOS) && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Hoja de captura de foto (UIImagePickerController, sourceType .camera). Entrega
/// un image block ya downscaleado (≤1568px, JPEG) para el turno multimodal.
public struct CameraPicker: UIViewControllerRepresentable {
    private let onCapture: (ContentBlock) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(onCapture: @escaping (ContentBlock) -> Void) {
        self.onCapture = onCapture
    }

    public func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        public func imagePickerController(_ picker: UIImagePickerController,
                                          didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            defer { parent.dismiss() }
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 1.0),
                  let block = ImageDownscaler.imageBlock(from: data) else { return }
            parent.onCapture(block)
        }

        public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif

#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
import Speech
import AVFoundation

/// Transcripción on-device (es-CO). El audio crudo no sale del teléfono: solo el
/// texto, que el llamador prefija con AudioTool.transcriptText (§ multimodal).
@MainActor
public final class SpeechTranscriber: ObservableObject {
    @Published public private(set) var transcript = ""
    @Published public private(set) var isRecording = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-CO"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public func start() throws {
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        self.request = request

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
        }
    }

    public func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
    }
}
#endif
