import Foundation
import UserNotifications

@MainActor
final class DownloadQueueService: ObservableObject {
    @Published private(set) var activeDownloadID: String?
    @Published private(set) var isProcessing = false

    private let settings: AppSettings
    private let offlineStore: OfflineStore
    private let notificationsEnabled: Bool

    init(settings: AppSettings, offlineStore: OfflineStore) {
        self.settings = settings
        self.offlineStore = offlineStore
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: "downloads.notificationsEnabled")
    }

    func download(_ file: RemoteFile) async {
        guard settings.isConfigured else {
            return
        }

        var record = offlineStore.createRecord(for: file)
        record.state = .downloading
        record.progress = 0
        record.lastError = nil
        offlineStore.update(record)

        activeDownloadID = file.path
        isProcessing = true

        defer {
            activeDownloadID = nil
            isProcessing = false
        }

        do {
            let client = WebDAVClient(settings: settings)
            let localURL = try await client.download(file) { [weak self] progress in
                Task { @MainActor in
                    self?.setProgress(file.path, progress)
                }
            }

            var completed = offlineStore.record(for: file) ?? record
            completed.localFileName = localURL.lastPathComponent
            completed.state = .downloaded
            completed.progress = 100
            completed.downloadedAt = Date()
            completed.lastError = nil
            completed.nextRetryAt = nil
            offlineStore.update(completed)

            notify(title: "Download complete", body: file.name)
        } catch {
            var failed = offlineStore.record(for: file) ?? record
            failed.state = .failed
            failed.lastError = error.localizedDescription
            failed.retryCount += 1

            let delay = min(pow(2, Double(failed.retryCount)), 60)
            failed.nextRetryAt = Date().addingTimeInterval(delay)
            offlineStore.update(failed)

            notify(title: "Download failed", body: "\(file.name): \(error.localizedDescription)")
        }
    }

    func retryFailed() async {
        let failedRecords = offlineStore.files.filter { $0.state == .failed }

        for record in failedRecords {
            var updated = record
            updated.state = .pending
            updated.nextRetryAt = nil
            updated.lastError = nil
            offlineStore.update(updated)

            let remoteFile = RemoteFile(
                id: record.id,
                name: record.name,
                path: record.remotePath,
                isDirectory: false,
                size: record.size,
                modifiedDate: nil,
                contentType: nil
            )

            await download(remoteFile)
        }
    }

    private func setProgress(_ path: String, _ progress: Double) {
        guard var record = offlineStore.files.first(where: { $0.id == path }) else {
            return
        }

        record.progress = progress
        offlineStore.update(record)
    }

    private func notify(title: String, body: String) {
        guard notificationsEnabled else {
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
