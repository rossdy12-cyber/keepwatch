import SwiftUI

struct NASFilesEmbeddedHostView: View {
    @StateObject private var settings: NFAppSettings
    @StateObject private var offlineStore: NFOfflineStore
    @StateObject private var downloadQueue: NFDownloadQueueService

    init() {
        let settings = NFAppSettings()
        let offlineStore = NFOfflineStore()

        _settings = StateObject(wrappedValue: settings)
        _offlineStore = StateObject(wrappedValue: offlineStore)
        _downloadQueue = StateObject(wrappedValue: NFDownloadQueueService(settings: settings, offlineStore: offlineStore))
    }

    var body: some View {
        NFRootView()
            .environmentObject(settings)
            .environmentObject(offlineStore)
            .environmentObject(downloadQueue)
    }
}
