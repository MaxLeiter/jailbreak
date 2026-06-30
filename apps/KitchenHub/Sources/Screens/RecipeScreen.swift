import SwiftUI
import Foundation

/// Native cook-mode recipe screen. Full-screen detail with a two-column layout
/// under the header: ingredients + serving scaling on the left, the current step
/// (big text, optional timer, prev/next) on the right. When there are no recipes
/// yet, an empty state invites the user to create one.
/// Orange (`KH.orange`) is the accent for the step / timer actions.
struct RecipeScreen: View {
    @EnvironmentObject var recipe: RecipeModel
    @EnvironmentObject var timers: TimersModel
    @EnvironmentObject var app: KHModel

    @State private var showingEditor = false
    @State private var editingRecipe: Recipe? = nil
    @State private var startEditorImporting = false
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if recipe.hasRecipes {
                cookMode
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KHBackground())
        .sheet(isPresented: $showingEditor) {
            RecipeEditorView(editing: editingRecipe, startImporting: startEditorImporting)
        }
    }

    // MARK: Actions

    private func presentCreate() {
        editingRecipe = nil
        startEditorImporting = false
        showingEditor = true
    }

    private func presentImport() {
        editingRecipe = nil
        startEditorImporting = true
        showingEditor = true
    }

    private func presentEdit() {
        guard let current = recipe.current else { return }
        editingRecipe = current
        startEditorImporting = false
        showingEditor = true
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Recipes", trailing: nil) { app.backToDashboard() }

            Spacer()
            VStack(spacing: 22) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(KH.textFaint)
                VStack(spacing: 6) {
                    Text("No recipes yet")
                        .font(KH.text(24, .semibold))
                        .foregroundStyle(KH.textPrimary)
                    Text("Add your first recipe to start cooking.")
                        .font(KH.text(16))
                        .foregroundStyle(KH.textSecondary)
                }
                HStack(spacing: 14) {
                    Button(action: presentCreate) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                            Text("New Recipe").font(KH.text(17, .semibold))
                        }
                        .foregroundStyle(KH.onAccent)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous).fill(KH.orange)
                        )
                        .shadow(color: KH.orange.opacity(0.35), radius: 12, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)

                    Button(action: presentImport) {
                        HStack(spacing: 8) {
                            Image(systemName: "link").font(.system(size: 16, weight: .semibold))
                            Text("Import from link").font(KH.text(17, .semibold))
                        }
                        .foregroundStyle(KH.textPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous).fill(KH.fill)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Spacer()
        }
    }

    // MARK: Cook mode

    private var cookMode: some View {
        VStack(spacing: 0) {
            header
            switcher

            GeometryReader { geo in
                let gap = KH.gap
                let leftWidth = max(0, (geo.size.width - gap) * 0.42)
                HStack(alignment: .top, spacing: gap) {
                    IngredientsCard()
                        .frame(width: leftWidth)
                    StepCard()
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
            .padding(.top, 4)
        }
        .confirmationDialog("Delete this recipe?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = recipe.current?.id { recipe.delete(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let title = recipe.current?.title { Text(title) }
        }
    }

    // MARK: Header (back · title · meta · edit · delete)

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            iconButton("arrow.left") { app.backToDashboard() }

            Text(recipe.current?.title ?? "Recipes")
                .font(KH.text(30, .bold))
                .foregroundStyle(KH.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.leading, 2)

            Spacer(minLength: 8)

            if let current = recipe.current {
                MonoLabel("\(current.minutes) MIN · \(current.difficulty.uppercased())", size: 13)
                    .layoutPriority(-1)
                iconButton("pencil") { presentEdit() }
                iconButton("trash", tint: KH.orange) { confirmingDelete = true }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func iconButton(_ system: String,
                            tint: Color = KH.textPrimary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(KH.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Recipe switcher (subtle chip row + add chip)

    private var switcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recipe.recipes) { r in
                    let isCurrent = r.id == recipe.current?.id
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            recipe.select(r.id)
                        }
                    } label: {
                        Text(r.title)
                            .font(KH.text(14, .medium))
                            .foregroundStyle(isCurrent ? KH.onAccent : KH.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isCurrent ? KH.orange : KH.fill)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: presentCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KH.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KH.fill)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Left column: ingredients + servings

private struct IngredientsCard: View {
    @EnvironmentObject var recipe: RecipeModel

    private var ingredients: [Ingredient] { recipe.current?.ingredients ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: KH.gap) {
            HStack(alignment: .center) {
                MonoLabel("INGREDIENTS")
                Spacer()
                ServingStepper()
            }

            if ingredients.isEmpty {
                Spacer(minLength: 0)
                Text("No ingredients")
                    .font(KH.text(15))
                    .foregroundStyle(KH.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(ingredients.enumerated()), id: \.element.id) { idx, ing in
                            IngredientRow(ing: ing)
                            if idx < ingredients.count - 1 {
                                Divider().overlay(KH.hairline)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .khCard()
    }
}

private struct ServingStepper: View {
    @EnvironmentObject var recipe: RecipeModel

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus") { recipe.setServings(recipe.servings - 1) }
            Text("\(recipe.servings) serv")
                .font(KH.mono(13, .medium))
                .foregroundStyle(KH.textPrimary)
                .frame(minWidth: 64)
                .contentTransition(.identity)
            stepButton("plus") { recipe.setServings(recipe.servings + 1) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KH.fill)
        )
    }

    private func stepButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(KH.textPrimary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KH.card.opacity(0.9))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct IngredientRow: View {
    @EnvironmentObject var recipe: RecipeModel
    let ing: Ingredient

    private var isChecked: Bool { recipe.checked.contains(ing.id) }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                recipe.toggle(ing)
            }
        } label: {
            HStack(spacing: 12) {
                checkbox
                Text(ing.name)
                    .font(KH.text(17, .regular))
                    .foregroundStyle(isChecked ? KH.textFaint : KH.textPrimary)
                    .strikethrough(isChecked, color: KH.textFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text(recipe.amountString(ing))
                    .font(KH.mono(14, .medium))
                    .foregroundStyle(KH.textFaint)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var checkbox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isChecked ? KH.orange : Color.clear)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isChecked ? Color.clear : KH.textFaint, lineWidth: 1.5)
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(KH.onAccent)
            }
        }
        .frame(width: 26, height: 26)
    }
}

// MARK: - Right column: cook-mode step

private struct StepCard: View {
    @EnvironmentObject var recipe: RecipeModel
    @EnvironmentObject var timers: TimersModel

    private var stepCount: Int { recipe.current?.steps.count ?? 0 }
    private var isFirst: Bool { recipe.stepIndex <= 0 }
    private var isLast: Bool { recipe.stepIndex >= stepCount - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: KH.gap) {
            HStack(alignment: .center) {
                MonoLabel("STEP \(min(recipe.stepIndex + 1, max(stepCount, 1))) OF \(stepCount)", color: KH.orange)
                Spacer()
                stepDots
            }

            Spacer(minLength: 0)

            Text(recipe.step?.text ?? "No steps yet")
                .font(KH.display(40, .regular))
                .foregroundStyle(recipe.step == nil ? KH.textFaint : KH.textPrimary)
                .lineSpacing(8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(recipe.stepIndex)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 24)),
                    removal: .opacity.combined(with: .offset(x: -24))
                ))

            if let step = recipe.step, let label = step.timerLabel, let minutes = step.timerMinutes {
                Button {
                    timers.add(name: label, minutes: minutes)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 9))
                        Text("Start \(label) timer")
                            .font(KH.text(17, .semibold))
                    }
                    .foregroundStyle(KH.onAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous).fill(KH.orange)
                    )
                    .shadow(color: KH.orange.opacity(0.35), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                navButton("Previous", systemImage: "arrow.left", tinted: false, disabled: isFirst) {
                    recipe.prevStep()
                }
                navButton("Next", systemImage: "arrow.right", tinted: true, disabled: isLast, trailingIcon: true) {
                    recipe.nextStep()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .khCard()
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: recipe.stepIndex)
    }

    private var stepDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<max(stepCount, 0), id: \.self) { i in
                Circle()
                    .fill(i == recipe.stepIndex ? KH.orange : KH.fill)
                    .frame(width: i == recipe.stepIndex ? 10 : 8,
                           height: i == recipe.stepIndex ? 10 : 8)
            }
        }
    }

    private func navButton(_ title: String,
                           systemImage: String,
                           tinted: Bool,
                           disabled: Bool,
                           trailingIcon: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { action() }
        } label: {
            HStack(spacing: 8) {
                if !trailingIcon { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(KH.text(17, .semibold))
                if trailingIcon { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
            }
            .foregroundStyle(tinted ? KH.onAccent : KH.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous)
                    .fill(tinted ? KH.orange : KH.fill)
            )
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
