import AppIntents
import SwiftUI
import WidgetKit

@main
struct LumenControlsBundle: WidgetBundle {
    var body: some Widget {
        OpenLumenControl()
    }
}

/// A button for Control Centre, the Lock Screen and the Action button that opens Lumen.
struct OpenLumenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.lumen.camera.open") {
            ControlWidgetButton(action: OpenLumenIntent()) {
                Label("Lumen", systemImage: "camera.aperture")
            }
        }
        .displayName("Lumen camera")
        .description("Opens the Lumen camera.")
    }
}
