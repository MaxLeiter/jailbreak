import SwiftUI

/// Create or edit a recipe. Presented as a sheet from `RecipeScreen`.
/// `editing == nil` → create a new recipe; otherwise edit the given one
/// (its `id` is preserved on save).
struct RecipeEditorView: View {
    @EnvironmentObject var recipe: RecipeModel
    @Environment(\.dismiss) private var dismiss

    private let editing: Recipe?
    private let startImporting: Bool

    @State private var title: String
    @State private var minutes: Int
    @State private var difficulty: String
    @State private var baseServings: Int
    @State private var ingredients: [EditIngredient]
    @State private var steps: [EditStep]

    // Import-from-link state.
    @State private var importURL = ""
    @State private var isImporting = false
    @State private var importError: String?
    @FocusState private var urlFieldFocused: Bool

    private let difficulties = ["Easy", "Medium", "Hard"]

    init(editing: Recipe?, startImporting: Bool = false) {
        self.editing = editing
        self.startImporting = startImporting
        _title       = State(initialValue: editing?.title ?? "")
        _minutes     = State(initialValue: editing?.minutes ?? 30)
        _difficulty  = State(initialValue: editing?.difficulty ?? "Easy")
        _baseServings = State(initialValue: editing?.baseServings ?? 2)
        _ingredients = State(initialValue: (editing?.ingredients ?? []).map(EditIngredient.init))
        _steps       = State(initialValue: (editing?.steps ?? []).map(EditStep.init))
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool { !trimmedTitle.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                importSection

                Section {
                    TextField("Recipe title", text: $title)
                        .font(KH.text(18, .semibold))
                }

                Section("Details") {
                    Stepper(value: $minutes, in: 1...600, step: 5) {
                        labeledValue("Time", "\(minutes) min")
                    }
                    Picker("Difficulty", selection: $difficulty) {
                        ForEach(difficulties, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper(value: $baseServings, in: 1...24) {
                        labeledValue("Base servings", "\(baseServings)")
                    }
                }

                ingredientsSection
                stepsSection
            }
            .scrollContentBackground(.hidden)
            .background(KH.bg.ignoresSafeArea())
            .navigationTitle(editing == nil ? "New Recipe" : "Edit Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
        .tint(KH.orange)
        .onAppear {
            guard startImporting else { return }
            // Slight delay so the sheet finishes presenting before focusing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                urlFieldFocused = true
            }
        }
    }

    // MARK: Import

    private var importSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(KH.orange)
                TextField("Paste recipe link", text: $importURL)
                    .focused($urlFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .disabled(isImporting)
                    .onSubmit(runImport)

                if isImporting {
                    ProgressView()
                } else {
                    Button("Import", action: runImport)
                        .font(KH.text(16, .semibold))
                        .buttonStyle(.borderless)
                        .tint(KH.orange)
                        .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(KH.text(13))
                    .foregroundStyle(KH.orange)
            }
        } header: {
            Text("Import")
        } footer: {
            Text("Paste a link to a recipe page and we'll fill in the details below for you to review.")
        }
    }

    private func runImport() {
        var input = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if !input.lowercased().hasPrefix("http") { input = "https://" + input }
        guard let url = URL(string: input), url.host != nil else {
            importError = RecipeImporter.ImportError.invalidURL.errorDescription
            return
        }

        importError = nil
        isImporting = true
        urlFieldFocused = false

        Task {
            do {
                let imported = try await RecipeImporter.fetch(url)
                await MainActor.run {
                    apply(imported)
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    importError = (error as? LocalizedError)?.errorDescription
                        ?? "Couldn't read a recipe from that link."
                    isImporting = false
                }
            }
        }
    }

    /// Populate the editor's fields from an imported recipe (no auto-save).
    private func apply(_ r: Recipe) {
        title = r.title
        if r.minutes > 0 { minutes = min(600, r.minutes) }
        difficulty = difficulties.contains(r.difficulty) ? r.difficulty : "Easy"
        baseServings = min(24, max(1, r.baseServings))
        ingredients = r.ingredients.map(EditIngredient.init)
        steps = r.steps.map(EditStep.init)
    }

    // MARK: Ingredients

    private var ingredientsSection: some View {
        Section {
            ForEach($ingredients) { $ing in
                HStack(spacing: 8) {
                    TextField("Name", text: $ing.name)
                    TextField("Amt", text: $ing.amount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    TextField("Unit", text: $ing.unit)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(KH.textSecondary)
                        .frame(width: 72)
                }
            }
            .onDelete { ingredients.remove(atOffsets: $0) }

            Button {
                ingredients.append(EditIngredient())
            } label: {
                Label("Add ingredient", systemImage: "plus.circle.fill")
            }
            .tint(KH.orange)
        } header: {
            Text("Ingredients")
        }
    }

    // MARK: Steps

    private var stepsSection: some View {
        Section {
            ForEach($steps) { $step in
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Step description", text: $step.text, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle("Add timer", isOn: $step.hasTimer.animation())
                        .font(KH.text(14))
                        .tint(KH.orange)
                    if step.hasTimer {
                        HStack(spacing: 8) {
                            TextField("Timer label", text: $step.timerLabel)
                            Stepper("\(step.timerMinutes) min",
                                    value: $step.timerMinutes, in: 1...600)
                                .fixedSize()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { steps.remove(atOffsets: $0) }
            .onMove { steps.move(fromOffsets: $0, toOffset: $1) }

            Button {
                steps.append(EditStep())
            } label: {
                Label("Add step", systemImage: "plus.circle.fill")
            }
            .tint(KH.orange)
        } header: {
            HStack {
                Text("Steps")
                Spacer()
                if !steps.isEmpty { EditButton() }
            }
        }
    }

    // MARK: Helpers

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(KH.textSecondary)
        }
    }

    private func save() {
        guard canSave else { return }
        let ings = ingredients.map { $0.toIngredient() }.filter { !$0.name.isEmpty }
        let stps = steps.map { $0.toStep() }.filter { !$0.text.isEmpty }

        if let editing {
            var r = editing
            r.title = trimmedTitle
            r.minutes = minutes
            r.difficulty = difficulty
            r.baseServings = baseServings
            r.ingredients = ings
            r.steps = stps
            recipe.update(r)
        } else {
            let r = Recipe(title: trimmedTitle, minutes: minutes, difficulty: difficulty,
                           baseServings: baseServings, ingredients: ings, steps: stps)
            recipe.add(r)
        }
        dismiss()
    }
}

// MARK: - Editable row models (string-backed for easy text binding)

private struct EditIngredient: Identifiable {
    let id: UUID
    var name: String
    var amount: String
    var unit: String

    init() { id = UUID(); name = ""; amount = ""; unit = "" }

    init(_ i: Ingredient) {
        id = i.id
        name = i.name
        amount = EditIngredient.format(i.amount)
        unit = i.unit
    }

    func toIngredient() -> Ingredient {
        let value = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        return Ingredient(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                          amount: value,
                          unit: unit.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func format(_ d: Double) -> String {
        if d == d.rounded() { return String(Int(d)) }
        return String(format: "%g", d)
    }
}

private struct EditStep: Identifiable {
    let id: UUID
    var text: String
    var hasTimer: Bool
    var timerLabel: String
    var timerMinutes: Int

    init() { id = UUID(); text = ""; hasTimer = false; timerLabel = ""; timerMinutes = 5 }

    init(_ s: RecipeStep) {
        id = s.id
        text = s.text
        hasTimer = s.timerLabel != nil || s.timerMinutes != nil
        timerLabel = s.timerLabel ?? ""
        timerMinutes = s.timerMinutes ?? 5
    }

    func toStep() -> RecipeStep {
        let label = timerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let useTimer = hasTimer && !label.isEmpty
        return RecipeStep(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          timerLabel: useTimer ? label : nil,
                          timerMinutes: useTimer ? timerMinutes : nil)
    }
}
