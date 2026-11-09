import Foundation
import Network
import UserNotifications

@MainActor
final class UploadQueueService: ObservableObject {
    @Published private(set) var isProcessing = false

    private let settings: AppSettings
    private let documentStore: DocumentStore
    private let preferences = UploadPreferences()
    private let monitor = NWPathMonitor()
    private var isWiFiAvailable = false

    init(settings: AppSettings, documentStore: DocumentStore) {
        self.settings = settings
        self.documentStore = documentStore
        startNetworkMonitoring()
    }

    var pendingUploads: [ScannedDocument] {
        documentStore.documents.filter {
            $0.uploadState == .pending || $0.uploadState == .uploading || $0.uploadState == .failed
        }
    }

    func enqueue(_ document: ScannedDocument) {
        var updated = document
        updated.uploadState = .pending
        updated.uploadProgress = 0
        updated.retryCount = 0
        updated.nextRetryAt = nil
        updated.lastUploadError = nil
        updated.uploadedAt = nil

        documentStore.update(updated)
    }

    func retryFailed() {
        for document in documentStore.pendingDocuments() where document.uploadState == .failed {
            var updated = document
            updated.uploadState = .pending
            updated.nextRetryAt = nil
            updated.lastUploadError = nil

            documentStore.update(updated)
        }
    }

    func processAll() async {
        guard !isProcessing else {
            return
        }

        guard settings.isConfigured else {
            return
        }

        if preferences.wifiOnly, !isWiFiAvailable {
            return
        }

        isProcessing = true
        defer {
            isProcessing = false
        }

        for document in documentStore.pendingDocuments() {
            if let nextRetry = document.nextRetryAt, nextRetry > Date() {
                continue
            }

            await upload(document)
        }
    }

    func upload(_ document: ScannedDocument) async {
        var updated = document
        updated.uploadState = .uploading
        updated.uploadProgress = 0
        documentStore.update(updated)

        do {
            let pdfURL = documentStore.localPDFURL(for: document)
            let pdfData = try Data(contentsOf: pdfURL)

            try await UploadService(settings: settings).upload(document, pdfData: pdfData) { [weak self] progress in
                Task { @MainActor in
                    self?.setProgress(document.id, progress)
                }
            }

            var uploaded = document
            uploaded.uploadState = .uploaded
            uploaded.uploadProgress = 100
            uploaded.lastUploadError = nil
            uploaded.nextRetryAt = nil
            uploaded.uploadedAt = Date()
            documentStore.update(uploaded)

            notify(title: "Upload complete", body: document.title)
        } catch {
            var failed = document
            failed.uploadState = .failed
            failed.lastUploadError = error.localizedDescription
            failed.retryCount += 1

            let delay = min(pow(2, Double(failed.retryCount)), 60)
            failed.nextRetryAt = Date().addingTimeInterval(delay)
            documentStore.update(failed)

            notify(title: "Upload failed", body: "\(document.title): \(error.localizedDescription)")
        }
    }

    private func setProgress(_ documentID: UUID, _ progress: Double) {
        guard let document = documentStore.documents.first(where: { $0.id == documentID }) else {
            return
        }

        var updated = document
        updated.uploadProgress = progress
        documentStore.update(updated)
    }

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isWiFiAvailable = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            }
        }

        monitor.start(queue: DispatchQueue(label: "vaultscan.network.monitor"))
    }

    private func notify(title: String, body: String) {
        guard preferences.notificationsEnabled else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
