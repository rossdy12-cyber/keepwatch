import AVFoundation
import SwiftUI
import UIKit

// MARK: - 1. iPhone Camera Barcode / SKU Scanner (#4)

struct BarcodeScannerSheet: View {
    var onScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BarcodeScannerRepresentable { code in
                    onScanned(code)
                    dismiss()
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Point camera at a Racebolt barcode or QR label")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle("Scan SKU / Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    var onCodeFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCodeFound = onCodeFound
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCodeFound: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var didEmit = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [
                    .ean13, .ean8, .upce, .code128, .code39, .code93, .qr, .dataMatrix
                ]
            }

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.addSublayer(preview)
            previewLayer = preview

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.layer.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !didEmit,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let stringValue = obj.stringValue, !stringValue.isEmpty else { return }
            didEmit = true
            session.stopRunning()
            onCodeFound?(stringValue)
        }
    }
}

// MARK: - 2. WooCommerce Stock & Price Editor Sheet (#4)

struct ProductStockEditorSheet: View {
    let product: WooProduct
    @EnvironmentObject private var hub: HubStore
    @Environment(\.dismiss) private var dismiss

    @State private var priceText = ""
    @State private var stockText = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    Text(product.name).font(.headline)
                    if let sku = product.sku, !sku.isEmpty {
                        LabeledContent("SKU", value: sku)
                    }
                }
                Section("Price & Stock") {
                    HStack {
                        Text("Price (£)")
                        Spacer()
                        TextField("0.00", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Stock Quantity")
                        Spacer()
                        TextField("e.g. 25", text: $stockText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .keepwatchChrome()
            .navigationTitle("Edit Stock & Price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            await hub.updateProductStockAndPrice(
                                product,
                                price: priceText.trimmingCharacters(in: .whitespaces),
                                stockQuantity: Int(stockText.trimmingCharacters(in: .whitespaces))
                            )
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(saving)
                }
            }
            .onAppear {
                priceText = product.regular_price ?? product.price
                if let q = product.stock_quantity {
                    stockText = String(q)
                }
            }
        }
    }
}

// MARK: - 3. Shared Handover Checklist & House Notes Card (#10)

struct SharedNotesCard: View {
    @EnvironmentObject private var bridge: HomelabBridgeStore
    @State private var newNote = ""

    var body: some View {
        Card(title: "Shared Handover Checklist & House Notes", symbol: "checklist.checked") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Add daily handover task or house note…", text: $newNote)
                        .padding(9)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        let trimmed = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        newNote = ""
                        var updated = bridge.sharedNotes
                        updated.append(SharedChecklistItem(text: trimmed, done: false))
                        Task { await bridge.saveSharedNotes(updated) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.gothicPurple)
                    }
                }

                ForEach(bridge.sharedNotes) { item in
                    HStack(spacing: 10) {
                        Button {
                            var updated = bridge.sharedNotes
                            if let idx = updated.firstIndex(where: { $0.id == item.id }) {
                                updated[idx].done.toggle()
                                Task { await bridge.saveSharedNotes(updated) }
                            }
                        } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? Theme.good : Theme.secondaryText)
                        }
                        .buttonStyle(.plain)

                        Text(item.text)
                            .font(.subheadline)
                            .strikethrough(item.done)
                            .foregroundStyle(item.done ? Theme.secondaryText : .white)

                        Spacer()

                        Button {
                            var updated = bridge.sharedNotes
                            updated.removeAll { $0.id == item.id }
                            Task { await bridge.saveSharedNotes(updated) }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await bridge.loadSystemBridge() }
    }
}
