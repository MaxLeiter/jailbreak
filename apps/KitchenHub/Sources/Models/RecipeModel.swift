import SwiftUI

struct Ingredient: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var amount: Double     // per `baseServings`
    var unit: String       // "g", "cloves", "tbsp", "cup", "tsp", "" …
}

struct RecipeStep: Identifiable, Equatable, Codable {
    var id = UUID()
    var text: String
    var timerLabel: String? = nil   // if set, the step offers a "Start <label> timer" button
    var timerMinutes: Int? = nil
}

struct Recipe: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    var minutes: Int
    var difficulty: String      // "Easy" / "Medium" / "Hard"
    var baseServings: Int
    var ingredients: [Ingredient]
    var steps: [RecipeStep]
}

/// Recipes + cook-mode state (current recipe, servings scaling, checked
/// ingredients, current step). Native — no web view.
///
/// Recipes are user-managed and persisted as JSON in the documents directory;
/// `servings`, `stepIndex` and `checked` are session-only (not persisted).
@MainActor
final class RecipeModel: ObservableObject {
    @Published var recipes: [Recipe]
    @Published var currentID: UUID?
    @Published var servings: Int
    @Published var stepIndex = 0
    @Published var checked: Set<UUID> = []

    private static func fileURL() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kh-recipes.json")
    }
    private let saveURL = RecipeModel.fileURL()

    /// The current recipe, or the first one as a fallback, or nil if there are none.
    var current: Recipe? { recipes.first { $0.id == currentID } ?? recipes.first }
    var hasRecipes: Bool { !recipes.isEmpty }

    /// The current cook-mode step, clamped to the current recipe (nil if none).
    var step: RecipeStep? {
        guard let c = current, !c.steps.isEmpty else { return nil }
        return c.steps[min(stepIndex, c.steps.count - 1)]
    }

    init() {
        let loaded = RecipeModel.decode(from: RecipeModel.fileURL())
        recipes = loaded
        currentID = loaded.first?.id
        servings = loaded.first?.baseServings ?? 0
    }

    // MARK: - Selection / cook-mode state

    func select(_ id: UUID) {
        currentID = id
        servings = current?.baseServings ?? 0
        stepIndex = 0
        checked = []
    }

    func setServings(_ n: Int) {
        guard current != nil else { return }
        servings = max(1, min(24, n))
    }

    func toggle(_ ingredient: Ingredient) {
        if checked.contains(ingredient.id) { checked.remove(ingredient.id) } else { checked.insert(ingredient.id) }
    }

    func nextStep() {
        guard let c = current else { return }
        stepIndex = min(stepIndex + 1, max(0, c.steps.count - 1))
    }

    func prevStep() {
        guard current != nil else { return }
        stepIndex = max(stepIndex - 1, 0)
    }

    /// Scaled, nicely-formatted amount for the current serving count.
    func amountString(_ ing: Ingredient) -> String {
        let base = max(1, current?.baseServings ?? 1)
        let count = servings > 0 ? servings : base
        let scaled = ing.amount * Double(count) / Double(base)
        if scaled <= 0 { return ing.unit }   // imported "to taste" items (amount 0) show no number
        let num: String
        if scaled == scaled.rounded() { num = String(Int(scaled)) }
        else { num = String(format: "%.2f", scaled).replacingOccurrences(of: ".00", with: "") }
        return ing.unit.isEmpty ? num : "\(num) \(ing.unit)"
    }

    // MARK: - CRUD

    func add(_ r: Recipe) {
        recipes.append(r)
        currentID = r.id
        servings = r.baseServings
        stepIndex = 0
        checked = []
        save()
    }

    func update(_ r: Recipe) {
        guard let idx = recipes.firstIndex(where: { $0.id == r.id }) else { return }
        recipes[idx] = r
        if r.id == currentID {
            // Keep session state coherent with the edited recipe.
            if servings <= 0 { servings = r.baseServings }
            stepIndex = min(stepIndex, max(0, r.steps.count - 1))
            checked = checked.intersection(Set(r.ingredients.map { $0.id }))
        }
        save()
    }

    func delete(_ id: UUID) {
        recipes.removeAll { $0.id == id }
        if currentID == id {
            currentID = recipes.first?.id
            servings = current?.baseServings ?? 0
            stepIndex = 0
            checked = []
        }
        save()
    }

    // MARK: - Persistence

    private static func decode(from url: URL) -> [Recipe] {
        guard let data = try? Data(contentsOf: url),
              let recipes = try? JSONDecoder().decode([Recipe].self, from: data)
        else { return [] }
        return recipes
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recipes) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }
}
