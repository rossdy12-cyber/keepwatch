import Foundation

/// Remembers one copied set of edits so it can be pasted onto other photos (or applied in a batch).
enum RecipeClipboard {
    private static let key = "lumen.editor.copiedRecipe"

    static func copy(_ recipe: EditRecipe) {
        if let data = try? JSONEncoder().encode(recipe) { UserDefaults.standard.set(data, forKey: key) }
    }

    static var stored: EditRecipe? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(EditRecipe.self, from: data)
    }

    static var hasValue: Bool { UserDefaults.standard.data(forKey: key) != nil }
}
