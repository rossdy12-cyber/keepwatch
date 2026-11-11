import SwiftUI
import WidgetKit

/// Holds the user's themes (presets + their own edits) and which one is active.
/// The active theme is mirrored into the App Group so the widget renders it.
@MainActor
final class ThemeStore: ObservableObject {
    @Published var themes: [ThemeSpec] { didSet { persist() } }
    @Published var selectedID: UUID { didSet { persistSelection() } }

    private let themesKey = "themes.v1"
    private let selectedKey = "selectedID.v1"
    private var defaults: UserDefaults { ThemeStorage.defaults }

    init() {
        // Compute into locals first: Swift forbids reading self.themes until every stored property is set.
        let loaded: [ThemeSpec]
        if let data = ThemeStorage.defaults.data(forKey: "themes.v1"),
           let saved = try? JSONDecoder().decode([ThemeSpec].self, from: data), !saved.isEmpty {
            loaded = saved
        } else {
            loaded = ThemePresets.all
        }
        let initialID: UUID
        if let s = ThemeStorage.defaults.string(forKey: "selectedID.v1"), let id = UUID(uuidString: s),
           loaded.contains(where: { $0.id == id }) {
            initialID = id
        } else {
            initialID = loaded[0].id
        }
        themes = loaded
        selectedID = initialID
        ThemeStorage.saveSelected(selected)
    }

    var selected: ThemeSpec {
        themes.first { $0.id == selectedID } ?? themes[0]
    }

    func select(_ spec: ThemeSpec) {
        selectedID = spec.id
        ThemeStorage.saveSelected(spec)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func update(_ spec: ThemeSpec) {
        if let i = themes.firstIndex(where: { $0.id == spec.id }) {
            themes[i] = spec
        } else {
            themes.append(spec)
        }
        if spec.id == selectedID {
            ThemeStorage.saveSelected(spec)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func duplicate(_ spec: ThemeSpec) -> ThemeSpec {
        var copy = spec
        copy.id = UUID()
        copy.name = spec.name + " Copy"
        themes.append(copy)
        return copy
    }

    func delete(_ spec: ThemeSpec) {
        guard themes.count > 1 else { return }
        themes.removeAll { $0.id == spec.id }
        if selectedID == spec.id { select(themes[0]) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(themes) { defaults.set(data, forKey: themesKey) }
    }
    private func persistSelection() {
        defaults.set(selectedID.uuidString, forKey: selectedKey)
    }
}
