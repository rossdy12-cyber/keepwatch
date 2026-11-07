import SwiftUI

/// Output file formats for saving and sharing.
enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case heic = "HEIC", jpeg = "JPEG", png = "PNG", tiff = "TIFF"
    var id: String { rawValue }
    var ext: String {
        switch self {
        case .heic: return "heic"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }
    var isLossy: Bool { self == .heic || self == .jpeg }
    var blurb: String {
        switch self {
        case .heic: return "Smallest files, great quality (Apple's default)."
        case .jpeg: return "Works everywhere."
        case .png: return "Lossless, larger files."
        case .tiff: return "Lossless, for other editors."
        }
    }
}

/// How the editor writes out a finished photo.
struct ExportOptions: Codable, Equatable {
    var format: ExportFormat = .heic
    var quality: Double = 0.92     // for HEIC/JPEG
    var maxDimension: Int = 0      // longest side in px; 0 = full resolution
    var stripLocation = true
    var stripMetadata = false      // drop all EXIF/camera info

    static let sizeChoices: [Int] = [0, 1280, 2048, 3200, 4096]

    static func load() -> ExportOptions {
        guard let data = UserDefaults.standard.data(forKey: "lumen.editor.export"),
              let value = try? JSONDecoder().decode(ExportOptions.self, from: data) else { return ExportOptions() }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "lumen.editor.export") }
    }
}

/// The export settings sheet (format, quality, size, metadata).
struct ExportOptionsSheet: View {
    @Binding var options: ExportOptions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $options.format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                } footer: {
                    Text(options.format.blurb)
                }

                if options.format.isLossy {
                    Section("Quality") {
                        Slider(value: $options.quality, in: 0.4...1)
                        Text("\(Int(options.quality * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Resize", selection: $options.maxDimension) {
                        ForEach(ExportOptions.sizeChoices, id: \.self) { size in
                            Text(size == 0 ? "Full resolution" : "\(size) px (longest side)").tag(size)
                        }
                    }
                } header: {
                    Text("Size")
                } footer: {
                    Text("Shrinks the longest side on export. Full resolution keeps every pixel.")
                }

                Section {
                    Toggle("Remove location", isOn: $options.stripLocation)
                    Toggle("Remove all metadata", isOn: $options.stripMetadata)
                } footer: {
                    Text("Removing metadata strips camera info, date and location — handy before sharing.")
                }
            }
            .navigationTitle("Export options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
