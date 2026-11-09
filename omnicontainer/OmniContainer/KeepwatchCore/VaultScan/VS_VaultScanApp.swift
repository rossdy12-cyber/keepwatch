import SwiftUI

struct VaultScanEmbeddedHostView: View {
    @StateObject private var settings: VSAppSettings
    @StateObject private var documentStore: VSDocumentStore
    @StateObject private var uploadQueue: VSUploadQueueService

    init() {
        let settings = VSAppSettings()
        let documentStore = VSDocumentStore()

        _settings = StateObject(wrappedValue: settings)
        _documentStore = StateObject(wrappedValue: documentStore)
        _uploadQueue = StateObject(wrappedValue: VSUploadQueueService(settings: settings, documentStore: documentStore))
    }

    var body: some View {
        VSRootView()
            .environmentObject(settings)
            .environmentObject(documentStore)
            .environmentObject(uploadQueue)
    }
}
