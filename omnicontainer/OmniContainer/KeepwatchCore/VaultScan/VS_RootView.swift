import SwiftUI

struct VSRootView: View {
    @EnvironmentObject private var documentStore: VSDocumentStore

    var body: some View {
        TabView {
            VSDocumentListView()
                .tabItem {
                    Label("Documents", systemImage: "doc.text.viewfinder")
                }

            VSSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    VSRootView()
        .environmentObject(VSAppSettings())
        .environmentObject(VSDocumentStore())
        .environmentObject(VSUploadQueueService(settings: VSAppSettings(), documentStore: VSDocumentStore()))
}
