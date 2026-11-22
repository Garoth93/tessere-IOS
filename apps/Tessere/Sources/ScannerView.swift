import SwiftUI
import UIKit
import AVFoundation
import Vision
import PhotosUI
import TessereCore

struct ScanResult: Equatable {
    let format: BarcodeFormat
    let payload: String
    /// Raw text for things that are not card codes (invite links).
    var raw: String { payload }
}

/// Live camera scanner (AVFoundation metadata output).
struct ScannerView: UIViewControllerRepresentable {
    var torch: Bool
    let onFound: (ScanResult) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onFound = onFound
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onFound = onFound
        controller.setTorch(torch)
    }

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.stop()
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((ScanResult) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var device: AVCaptureDevice?
    private var delivered = false
    private let queue = DispatchQueue(label: "tessere.scanner")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        self.device = device
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { session.commitConfiguration(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        let wanted: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128, .code39, .code39Mod43,
                                                     .interleaved2of5, .itf14, .codabar, .qr, .pdf417, .aztec]
        output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        delivered = false
        let s = session
        queue.async { if !s.isRunning { s.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // Delegate queue is .main.
        MainActor.assumeIsolated { handle(metadataObjects) }
    }

    private func handle(_ metadataObjects: [AVMetadataObject]) {
        guard !delivered else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue, !value.isEmpty,
                  let format = BarcodeFormat.fromScanner(code.type.rawValue) else { continue }
            delivered = true
            let (f, p) = BarcodeFormat.normalizeScan(format: format, payload: value)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFound?(ScanResult(format: f, payload: p))
            return
        }
    }
}

/// Reads a code from a photo (screenshot of a card, photo of the back…).
enum PhotoBarcodeReader {
    static func read(_ image: UIImage) async -> ScanResult? {
        guard let cg = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> ScanResult? in
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
            for obs in request.results ?? [] {
                guard let payload = obs.payloadStringValue, !payload.isEmpty,
                      let format = BarcodeFormat.fromVision(obs.symbology.rawValue) else { continue }
                let (f, p) = BarcodeFormat.normalizeScan(format: format, payload: payload)
                return ScanResult(format: f, payload: p)
            }
            return nil
        }.value
    }
}

enum CameraAccess {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// Camera with a framing overlay, torch, "from photo" and "manual" actions.
struct ScannerScreen: View {
    let title: String
    let hint: String
    var showManual = true
    let onResult: (ScanResult) -> Void
    var onManual: (() -> Void)? = nil

    @State private var allowed: Bool?
    @State private var torch = false
    @State private var readingPhoto = false
    @State private var photoFailed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if allowed == true {
                ScannerView(torch: torch, onFound: onResult)
                    .ignoresSafeArea()
                frame
            } else if allowed == false {
                ContentUnavailableView {
                    Label("Fotocamera non disponibile", systemImage: "camera.fill")
                } description: {
                    Text("Consenti l'accesso alla fotocamera in Impostazioni › Tessere, oppure inserisci il numero a mano.")
                } actions: {
                    Button("Apri Impostazioni") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                .foregroundStyle(.white)
            }
            VStack {
                Spacer()
                controls
            }
        }
        .environment(\.colorScheme, .dark)
        .task { allowed = await CameraAccess.request() }
        .alert("Nessun codice trovato nella foto", isPresented: $photoFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var frame: some View {
        VStack(spacing: 14) {
            Text(hint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45), in: Capsule())
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 3)
                .frame(width: 290, height: 190)
                .shadow(color: Theme.accent.opacity(0.6), radius: 14)
        }
        .offset(y: -60)
        .allowsHitTesting(false)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            PhotoPickButton(reading: $readingPhoto) { image in
                if let r = await PhotoBarcodeReader.read(image) {
                    onResult(r)
                } else {
                    photoFailed = true
                }
            }
            if allowed == true {
                Button {
                    torch.toggle()
                    Haptics.selection()
                } label: {
                    Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3)
                        .frame(width: 56, height: 56)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(torch ? "Spegni torcia" : "Accendi torcia")
            }
            if showManual, let onManual {
                Button(action: onManual) {
                    Label("A mano", systemImage: "keyboard")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .frame(height: 56)
                }
                .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.bottom, 28)
    }
}

/// Button that lets the user pick a photo and hands it over as UIImage.
struct PhotoPickButton: View {
    @Binding var reading: Bool
    var label: String? = nil
    let onImage: (UIImage) async -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Group {
                if reading {
                    ProgressView().tint(.white)
                } else if let label {
                    Label(label, systemImage: "photo")
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                }
            }
            .frame(minWidth: 56, minHeight: 56)
            .padding(.horizontal, label == nil ? 0 : 16)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(label ?? "Leggi da foto")
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            reading = true
            Task {
                defer { reading = false; item = nil }
                if let data = try? await newItem.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await onImage(image)
                }
            }
        }
    }
}
