import SwiftUI

/// Less-used camera settings, behind the gear button.
struct CameraSettingsSheet: View {
    @ObservedObject var camera: CameraModel
    @Binding var hardwareShutter: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lumen.camera.stripLocation") private var stripLocation = true
    @AppStorage("lumen.camera.haptics") private var haptics = true
    @AppStorage("lumen.camera.autoEnhance") private var autoEnhance = true
    @AppStorage("lumen.camera.saveTarget") private var saveTarget = SaveTarget.immich.rawValue
    @State private var pendingBackups = NASBackup.shared.pendingCount
    @State private var immich = ImmichSettings.load()
    @State private var immichTest: String?
    @State private var testingImmich = false
    @State private var pendingImmich = ImmichBackup.shared.pendingCount

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if camera.maxResolutionAvailable {
                        Picker("Resolution", selection: Binding(get: { camera.resolution }, set: { camera.setResolution($0) })) {
                            Text("Max (\(camera.maxResolutionLabel))").tag(PhotoResolution.max)
                            Text("12 MP (smaller, better in low light)").tag(PhotoResolution.standard)
                        }
                    }
                    Toggle("Auto-enhance photos", isOn: $autoEnhance)
                    Toggle("Mirror selfies (front camera)", isOn: $camera.mirrorFront)
                    Toggle("Volume buttons & Camera Control take photos", isOn: $hardwareShutter)
                    Toggle("Haptic taps", isOn: $haptics)
                    Toggle("Tag photos with location", isOn: $camera.locationTagging)
                    Toggle("Remove location when sharing", isOn: $stripLocation)
                    Toggle("Live Photos", isOn: $camera.livePhoto)
                    Toggle("Save into a “Lumen” album", isOn: $camera.saveToAlbum)
                    Toggle("Spot QR codes and documents", isOn: $camera.detectCodes)
                } header: {
                    Text("Shooting")
                } footer: {
                    Text("Lumen remembers your last mode, format, drive, shape, look and grid. Max resolution uses the full sensor (48 MP on the main camera); 12 MP is smaller and cleaner in low light. Hold a volume button in Burst for continuous shots. On iPhone 16, press Camera Control lightly for zoom, exposure and look. The album needs full Photos access.")
                }

                Section {
                    Picker("Save photos to", selection: $saveTarget) {
                        ForEach(SaveTarget.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    TextField("Immich address", text: $immich.address)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API key", text: $immich.key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        testingImmich = true
                        immichTest = nil
                        Task {
                            do {
                                let who = try await ImmichClient(settings: immich).check()
                                immichTest = "Connected as \(who)."
                                ImmichBackup.shared.kick()
                            } catch {
                                immichTest = error.localizedDescription
                            }
                            testingImmich = false
                            pendingImmich = ImmichBackup.shared.pendingCount
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testingImmich { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!immich.isConfigured || testingImmich)
                    if let immichTest { Text(immichTest).font(.footnote).foregroundStyle(.secondary) }
                    if pendingImmich > 0 {
                        LabeledContent("Waiting to upload", value: "\(pendingImmich)")
                        Button("Upload now") {
                            ImmichBackup.shared.kick()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pendingImmich = ImmichBackup.shared.pendingCount }
                        }
                    }
                } header: {
                    Text("Immich")
                } footer: {
                    Text("Get an API key from Immich → Account Settings → API Keys. With “Immich (save space)”, new photos upload straight to Immich and skip the iPhone’s Photos library — they wait on the phone until Immich has them, then they’re gone from the phone. If Immich isn’t set up yet, photos are kept in Photos so nothing is lost. The in-app Library browses Immich.")
                }
                .onChange(of: immich) { _ in immich.save() }

                Section {
                    Toggle("Back up originals to my NAS", isOn: $camera.nasBackup)
                    if camera.nasBackup {
                        LabeledContent("Waiting to upload", value: "\(pendingBackups)")
                        Button("Try uploading now") {
                            NASBackup.shared.kick()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pendingBackups = NASBackup.shared.pendingCount }
                        }
                    }
                } header: {
                    Text("NAS backup")
                } footer: {
                    Text("Every new photo (RAW too) and video is copied to the lumen-ai app on your NAS, using the address and key from the editor's AI tab. Files wait on the iPhone until the NAS can be reached (Tailscale or home Wi-Fi).")
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
                    if camera.hdrVideoAvailable {
                        Toggle("HDR video (Dolby Vision)", isOn: $camera.hdrVideo)
                    }
                    Picker("Stabilisation", selection: $camera.stabilization) {
                        ForEach(StabilizationChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Save slow motion as", selection: $camera.slowMoEditable) {
                        Text("iPhone Slo-mo (editable)").tag(true)
                        Text("Already slowed down").tag(false)
                    }
                    Picker("Frame guides", selection: $camera.frameGuide) {
                        ForEach(FrameGuide.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Anamorphic lens", selection: $camera.anamorphic) {
                        Text("None").tag(1.0)
                        Text("1.33×").tag(1.33)
                        Text("1.55×").tag(1.55)
                        Text("2×").tag(2.0)
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

                Section("Open Lumen quickly") {
                    Text("Control Centre or Lock Screen: edit them, tap Add a Control, and search for Lumen. The Action button can open it too (Settings → Action Button → Controls). Opening Lumen straight from the Camera Control or a locked screen without unlocking isn't possible for this app: Apple only allows that for apps it has signed with a special lock-screen camera extension.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        var lines = ["Anamorphic stretches the preview back out; the recording stays squeezed for your editor. Frame guides assume you're holding the iPhone sideways.",
                     "Auto 180°: the shutter stays at half the frame time (1/48 at 24 fps, 1/60 at 30) for natural motion blur; ISO follows the light. Microphone choice works in Video and Slo-mo."]
        if !camera.logAvailable || !camera.proResAvailable {
            lines.append("Apple Log and ProRes appear here (in Video mode) on iPhones that support them – Pro models only, so not on iPhone 16.")
        }
        return lines.joined(separator: " ")
    }
}
