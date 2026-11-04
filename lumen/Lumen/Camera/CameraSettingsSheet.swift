import SwiftUI

/// Less-used camera settings, behind the gear button.
struct CameraSettingsSheet: View {
    @ObservedObject var camera: CameraModel
    @Binding var hardwareShutter: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Volume buttons & Camera Control take photos", isOn: $hardwareShutter)
                    Toggle("Tag photos with location", isOn: $camera.locationTagging)
                } header: {
                    Text("Shooting")
                } footer: {
                    Text("Hold a volume button in Burst for continuous shots. On iPhone 16, press Camera Control lightly for zoom, exposure and look.")
                }

                Section("Photo") {
                    Toggle("Auto macro", isOn: $camera.autoMacro)
                    Toggle("HDR: also keep the 3 separate shots", isOn: $camera.keepBracketFrames)
                    Picker("Long exposure", selection: $camera.longExposureStyle) {
                        ForEach(LongExposureStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Long exposure length", selection: $camera.longExposureSeconds) {
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("4 seconds").tag(4.0)
                    }
                    Toggle("On a tripod (no hand-shake correction)", isOn: $camera.onTripod)
                    Picker("Interval: every", selection: $camera.intervalSeconds) {
                        ForEach([2.0, 5, 10, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    Picker("Interval: photos", selection: $camera.intervalShots) {
                        Text("10").tag(10)
                        Text("30").tag(30)
                        Text("100").tag(100)
                        Text("Until stopped").tag(0)
                    }
                }

                Section("Overlays") {
                    Picker("Zebras from", selection: $camera.zebraLevel) {
                        Text("90%").tag(0.9)
                        Text("95%").tag(0.95)
                        Text("100% (clipped)").tag(0.99)
                    }
                }

                Section {
                    Picker("Slow motion", selection: $camera.slowMoRate) {
                        ForEach(SlowMoRate.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Time-lapse: a frame every", selection: $camera.timeLapseInterval) {
                        ForEach([0.25, 0.5, 1, 2, 5], id: \.self) { value in
                            Text(value < 1 ? "\(value, specifier: "%.2g") s" : "\(Int(value)) s").tag(value)
                        }
                    }
                    Toggle("Auto 180° shutter", isOn: Binding(get: { camera.auto180 }, set: { camera.setAuto180($0) }))
                        .disabled(!camera.mode.isVideo)
                    Picker("Focus pull speed", selection: $camera.focusPullSeconds) {
                        ForEach([1.0, 2, 3, 5], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    Picker("Microphone", selection: Binding(get: { camera.micID ?? "" }, set: { id in
                        camera.selectMic(camera.micOptions.first { $0.id == id })
                    })) {
                        Text("Automatic").tag("")
                        ForEach(camera.micOptions) { Text($0.name).tag($0.id) }
                    }
                    .disabled(camera.mode != .video && camera.mode != .slowMo)
                    if camera.logAvailable {
                        Toggle("Apple Log", isOn: $camera.useLog)
                    }
                    if camera.proResAvailable {
                        Toggle("ProRes", isOn: $camera.useProRes)
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text(videoFooter)
                }

                Section("Custom settings") {
                    Text("Tap C1, C2 or C3 on the viewfinder to load a set of settings. Long-press one to save what you're using now: mode, drive, format, lens and zoom, exposure, white balance, focus, look and shape.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Camera settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { camera.refreshMics() }
        }
        .preferredColorScheme(.dark)
    }

    private var videoFooter: String {
        var lines = ["Auto 180°: the shutter stays at half the frame time (1/48 at 24 fps, 1/60 at 30) for natural motion blur; ISO follows the light. Microphone choice works in Video and Slo-mo."]
        if !camera.logAvailable || !camera.proResAvailable {
            lines.append("Apple Log and ProRes appear here (in Video mode) on iPhones that support them – Pro models only, so not on iPhone 16.")
        }
        return lines.joined(separator: " ")
    }
}
