import SwiftUI

@main
struct LumenApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .tint(.yellow)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
