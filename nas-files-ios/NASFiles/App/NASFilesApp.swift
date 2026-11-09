import SwiftUI

@main
struct NASFilesApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var offlineStore: OfflineStore
    @StateObject private var downloadQueue: DownloadQueueService

    init() {
        let settings = AppSettings()
        let offlineStore = OfflineStore()

        _settings = StateObject(wrappedValue: settings)
        _offlineStore = StateObject(wrappedValue: offlineStore)
        _downloadQueue = StateObject(wrappedValue: DownloadQueueService(settings: settings, offlineStore: offlineStore))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(offlineStore)
                .environmentObject(downloadQueue)
        }
    }
}
