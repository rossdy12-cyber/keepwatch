import SwiftUI

struct EditorView: View {
    @EnvironmentObject var store: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State var spec: ThemeSpec

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ThemeBackground(spec: spec)
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Theme name", text: $spec.name)
                }

                Section("Style") {
                    Picker("Style", selection: $spec.style) {
                        ForEach(ThemeStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Light text on top", isOn: $spec.lightText)
                }

                Section("Palette") {
                    ForEach(spec.colors.indices, id: \.self) { i in
                        ColorPicker(colorLabel(i), selection: colorBinding(i), supportsOpacity: false)
                    }
                    HStack {
                        Button {
                            if spec.colors.count < 4 { spec.colors.append(spec.colors.last ?? "FFFFFF") }
                        } label: { Label("Add colour", systemImage: "plus.circle") }
                            .disabled(spec.colors.count >= 4)
                        Spacer()
                        Button(role: .destructive) {
                            if spec.colors.count > 1 { spec.colors.removeLast() }
                        } label: { Label("Remove", systemImage: "minus.circle") }
                            .disabled(spec.colors.count <= 1)
                    }
                    .font(.subheadline)
                }

                Section("Accent") {
                    ColorPicker("Glyph / highlight", selection: accentBinding, supportsOpacity: false)
                }
            }
            .navigationTitle("Edit Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        store.update(spec)
                        store.select(spec)
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
    }

    private func colorLabel(_ i: Int) -> String {
        switch i {
        case 0: return "Colour 1 (top)"
        case spec.colors.count - 1: return "Colour \(i + 1) (bottom)"
        default: return "Colour \(i + 1)"
        }
    }

    private func colorBinding(_ i: Int) -> Binding<Color> {
        Binding(
            get: { Color(hex: spec.colors[i]) },
            set: { spec.colors[i] = $0.hexString() }
        )
    }
    private var accentBinding: Binding<Color> {
        Binding(get: { Color(hex: spec.accent) }, set: { spec.accent = $0.hexString() })
    }
}
