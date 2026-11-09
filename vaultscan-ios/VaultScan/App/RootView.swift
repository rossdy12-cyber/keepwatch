import SwiftUI

struct RootView: View {
    @EnvironmentObject private var documentStore: DocumentStore

    var body: some View {
        TabView {
            DocumentListView()
                .tabItem {
                    Label("Documents", systemImage: "doc.text.viewfinder")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(DocumentStore())
        .environmentObject(UploadQueueService(settings: AppSettings(), documentStore: DocumentStore()))
}
