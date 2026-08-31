#if os(iOS)
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// A small native QR scanner for Relay pairing links. The scanner returns the
/// URL only; parsing, ticket exchange, and credential storage stay in the
/// Transport/model layers.
public struct IOSRelayPairingScannerView: UIViewControllerRepresentable {
    public let onCode: (URL) -> Void
    public let onPaste: () -> Void
    public let onCancel: () -> Void

    public init(
        onCode: @escaping (URL) -> Void,
        onPaste: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) {
        self.onCode = onCode
        self.onPaste = onPaste
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onPaste: onPaste, onCancel: onCancel)
    }

    public func makeUIViewController(context: Context) -> RelayQRScannerViewController {
        let controller = RelayQRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ controller: RelayQRScannerViewController, context: Context) {
        controller.delegate = context.coordinator
    }

    public static func dismantleUIViewController(_ controller: RelayQRScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    public final class Coordinator: NSObject, RelayQRScannerDelegate {
        private let onCode: (URL) -> Void
        private let onPaste: () -> Void
        private let onCancel: () -> Void

        init(
            onCode: @escaping (URL) -> Void,
            onPaste: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onCode = onCode
            self.onPaste = onPaste
            self.onCancel = onCancel
        }

        public func scanner(_ scanner: RelayQRScannerViewController, didRead url: URL) {
            onCode(url)
        }

        public func scannerDidRequestPaste(_ scanner: RelayQRScannerViewController) {
            onPaste()
        }

        public func scannerDidCancel(_ scanner: RelayQRScannerViewController) {
            onCancel()
        }
    }
}

public protocol RelayQRScannerDelegate: AnyObject {
    func scanner(_ scanner: RelayQRScannerViewController, didRead url: URL)
    func scannerDidRequestPaste(_ scanner: RelayQRScannerViewController)
    func scannerDidCancel(_ scanner: RelayQRScannerViewController)
}

@MainActor
public final class RelayQRScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    public weak var delegate: RelayQRScannerDelegate?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReadCode = false
    private var messageLabel: UILabel?
    private var cancelButton: UIButton?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureOverlay()
        // Build the overlay before requesting camera access. If permission is
        // denied, `configureCapture` reports the paste fallback immediately;
        // having the label already installed avoids creating the overlay twice.
        configureCapture()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    public func startScanning() {
        guard !captureSession.isRunning, !didReadCode else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    public func stopScanning() {
        guard captureSession.isRunning else { return }
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReadCode,
              let value = metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .compactMap(\.stringValue)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }),
              let url = URL(string: value) else {
            showMessage("This QR code is not a Warren Relay link.")
            return
        }
        didReadCode = true
        stopScanning()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        delegate?.scanner(self, didRead: url)
    }

    private func configureCapture() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAuthorizedCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAuthorizedCapture()
                        self.startScanning()
                    } else {
                        self.showMessage("Camera access is unavailable. Paste the Relay link instead.")
                    }
                }
            }
        case .denied, .restricted:
            showMessage("Camera access is unavailable. Paste the Relay link instead.")
        @unknown default:
            showMessage("Camera access is unavailable. Paste the Relay link instead.")
        }
    }

    private func configureAuthorizedCapture() {
        guard previewLayer == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            showMessage("Camera access is unavailable. Paste the Relay link instead.")
            return
        }
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            showMessage("QR scanning is unavailable on this device.")
            return
        }
        captureSession.addInput(input)
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    private func configureOverlay() {
        guard messageLabel == nil else { return }
        let label = UILabel()
        label.text = "Scan Warren Relay QR"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
        ])
        messageLabel = label

        let border = UIView()
        border.isUserInteractionEnabled = false
        border.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        border.layer.borderWidth = 2
        border.layer.cornerRadius = 18
        border.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(border)
        NSLayoutConstraint.activate([
            border.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            border.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            border.widthAnchor.constraint(equalToConstant: 238),
            border.heightAnchor.constraint(equalToConstant: 238),
        ])

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancel.addTarget(self, action: #selector(cancelScanning), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
        cancelButton = cancel

        let paste = UIButton(type: .system)
        paste.setTitle("Paste link", for: .normal)
        paste.setTitleColor(UIColor.white.withAlphaComponent(0.9), for: .normal)
        paste.titleLabel?.font = .preferredFont(forTextStyle: .body)
        paste.addTarget(self, action: #selector(requestPaste), for: .touchUpInside)
        paste.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paste)
        NSLayoutConstraint.activate([
            paste.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            paste.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -2),
            paste.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            paste.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    @objc private func requestPaste() {
        stopScanning()
        delegate?.scannerDidRequestPaste(self)
    }

    @objc private func cancelScanning() {
        stopScanning()
        delegate?.scannerDidCancel(self)
    }

    private func showMessage(_ message: String) {
        if messageLabel == nil { configureOverlay() }
        messageLabel?.text = message
        messageLabel?.numberOfLines = 0
    }
}
#else
import SwiftUI

/// Preview/test fallback for the macOS package destination. Production iOS
/// builds use the AVFoundation implementation above.
public struct IOSRelayPairingScannerView: View {
    public let onCode: (URL) -> Void
    public let onPaste: () -> Void
    public let onCancel: () -> Void

    public init(
        onCode: @escaping (URL) -> Void,
        onPaste: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) {
        self.onCode = onCode
        self.onPaste = onPaste
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 30))
            Text("QR scanning is available on iPhone and iPad.")
                .multilineTextAlignment(.center)
            Button("Paste Relay link", action: onPaste)
            Button("Close", action: onCancel)
        }
        .padding(24)
    }
}
#endif
