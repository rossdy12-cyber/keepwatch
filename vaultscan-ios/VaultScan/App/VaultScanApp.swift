import SwiftUI

@main
struct VaultScanApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var documentStore: DocumentStore
    @StateObject private var uploadQueue: UploadQueueService

    init() {
        let settings = AppSettings()
        let documentStore = DocumentStore()

        _settings = StateObject(wrappedValue: settings)
        _documentStore = StateObject(wrappedValue: documentStore)
        _uploadQueue = StateObject(wrappedValue: UploadQueueService(settings: settings, documentStore: documentStore))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(documentStore)
                .environmentObject(uploadQueue)
        }
    }
}
