import SwiftUI

struct CustomizeView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var speaker: Speaker
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Companion
    let isNew: Bool

    init(companion: Companion, isNew: Bool) {
        _draft = State(initialValue: companion)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CreatureView(style: draft.style)
                        .frame(height: 150).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    TextField("Name", text: $draft.name)
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                }

                Section("Colour") {
                    row(Palette.bodies.map { hex in
                        ColourDot(hex: hex, chosen: draft.style.bodyColorHex == hex) { draft.style.bodyColorHex = hex }
                    })
                }
                Section("Body") {
                    row(BodyShape.allCases.map { s in
                        CreatureSwatch(style: style(\.bodyShape, s), chosen: draft.style.bodyShape == s) { draft.style.bodyShape = s }
                    })
                }
                Section("Eyes") {
                    row(EyeStyle.allCases.map { s in
                        CreatureSwatch(style: style(\.eyeStyle, s), chosen: draft.style.eyeStyle == s) { draft.style.eyeStyle = s }
                    })
                }
                Section("Mouth") {
                    row(MouthStyle.allCases.map { s in
                        CreatureSwatch(style: style(\.mouthStyle, s), chosen: draft.style.mouthStyle == s) { draft.style.mouthStyle = s }
                    })
                }
                Section("Accessory") {
                    row(Accessory.allCases.map { a in
                        CreatureSwatch(style: style(\.accessory, a), chosen: draft.style.accessory == a, label: a.label) { draft.style.accessory = a }
                    })
                }

                Section("Who they are") {
                    Picker("They're my…", selection: $draft.role) { ForEach(Role.allCases) { Text($0.label).tag($0) } }
                    Picker("Vibe", selection: $draft.tone) { ForEach(Tone.allCases) { Text($0.label).tag($0) } }
                    TextField("They call me… (optional)", text: $draft.callsYou)
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(traitCatalog, id: \.self) { trait in
                            TraitChip(trait: trait, on: draft.traits.contains(trait)) { toggleTrait(trait) }
                        }
                    }
                } header: { Text("Personality") } footer: { Text("Pick up to 5 traits — they shape how your companion talks.") }
                Section("Backstory (optional)") {
                    TextField("e.g. A curious little explorer from a faraway star.", text: $draft.backstory, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Voice") {
                    Picker("Voice", selection: Binding(get: { draft.voiceId ?? "" }, set: { draft.voiceId = $0.isEmpty ? nil : $0 })) {
                        Text("Default (British)").tag("")
                        ForEach(Speaker.englishVoices(), id: \.identifier) { v in
                            Text("\(v.name) (\(v.language))").tag(v.identifier)
                        }
                    }
                    HStack { Text("Pitch"); Slider(value: $draft.pitch, in: 0.6...1.6) }
                    Button {
                        speaker.speak("Hi! I'm \(draft.name.isEmpty ? "your companion" : draft.name).", voiceId: draft.voiceId, pitch: draft.pitch)
                    } label: { Label("Hear a hello", systemImage: "speaker.wave.2.fill") }
                }
            }
            .navigationTitle(isNew ? "New companion" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { speaker.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        speaker.stop()
                        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = "Companion" }
                        store.upsert(draft)
                        dismiss()
                    }
                }
            }
        }
    }

    private func style<V>(_ keyPath: WritableKeyPath<CreatureStyle, V>, _ value: V) -> CreatureStyle {
        var s = draft.style; s[keyPath: keyPath] = value; return s
    }

    private func toggleTrait(_ trait: String) {
        if let i = draft.traits.firstIndex(of: trait) { draft.traits.remove(at: i) }
        else if draft.traits.count < 5 { draft.traits.append(trait) }
    }

    private func row<V: View>(_ views: [V]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { ForEach(views.indices, id: \.self) { views[$0] } }.padding(.vertical, 4)
        }
    }
}

private struct ColourDot: View {
    let hex: String; let chosen: Bool; let action: () -> Void
    var body: some View {
        Circle().fill(Color(hex: hex)).frame(width: 38, height: 38)
            .overlay(Circle().stroke(Theme.accent, lineWidth: chosen ? 3 : 0))
            .onTapGesture(perform: action)
    }
}

private struct CreatureSwatch: View {
    let style: CreatureStyle
    let chosen: Bool
    var label: String? = nil
    let action: () -> Void
    var body: some View {
        VStack(spacing: 2) {
            CreatureView(style: style, animated: false).frame(width: 54, height: 54)
            if let label { Text(label).font(.system(size: 9)).foregroundStyle(Theme.secondaryText) }
        }
        .padding(4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, lineWidth: chosen ? 2.5 : 0))
        .onTapGesture(perform: action)
    }
}

private struct TraitChip: View {
    let trait: String; let on: Bool; let action: () -> Void
    var body: some View {
        Text(trait)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(on ? Theme.accent : Theme.surface, in: Capsule())
            .foregroundStyle(on ? .white : Theme.secondaryText)
            .onTapGesture(perform: action)
    }
}
