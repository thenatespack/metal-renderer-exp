struct CraftingGridCell {
    var type: VoxelType?
    var count: Int
}

/// The 3x3 grid items get dragged into (see InventoryView) — separate from
/// the hotbar, since its contents sit there mid-craft rather than being part
/// of the player's held inventory. Owned by InventoryView as a persistent
/// property, so a partially-filled grid survives closing and reopening the
/// inventory within a session, same as it would in most crafting UIs.
///
/// Recipes are shapeless (only ingredient totals matter, not which cell
/// holds what — see CraftingRecipe), so matching just sums by type across
/// every cell rather than checking a specific arrangement.
final class CraftingGrid {
    let columns = 3
    let rows = 3

    private(set) var cells: [CraftingGridCell]

    init() {
        cells = Array(repeating: CraftingGridCell(type: nil, count: 0), count: columns * rows)
    }

    var isEmpty: Bool { cells.allSatisfy { $0.type == nil } }

    func totalCount(of type: VoxelType) -> Int {
        cells.filter { $0.type == type }.reduce(0) { $0 + $1.count }
    }

    /// Places into the first cell already holding `type`, or the first empty
    /// cell otherwise. Silently drops anything that doesn't fit (grid full
    /// of unrelated types) — callers only ever add amounts already known to
    /// have come out of the hotbar via Hotbar.remove, so losing them here
    /// would mean they'd simply vanish; in practice this only matters if the
    /// grid is already full when a drag/auto-fill happens.
    func add(_ type: VoxelType, count: Int) {
        guard count > 0 else { return }
        if let index = cells.firstIndex(where: { $0.type == type }) {
            cells[index].count += count
            return
        }
        if let index = cells.firstIndex(where: { $0.type == nil }) {
            cells[index] = CraftingGridCell(type: type, count: count)
        }
    }

    /// Places directly into a specific cell (drag-and-drop target) — merges
    /// if that cell already holds the same type, replaces if empty, and is
    /// rejected (returns false, nothing changes) if it holds something else.
    @discardableResult
    func place(_ type: VoxelType, count: Int, at index: Int) -> Bool {
        guard cells.indices.contains(index) else { return false }
        if cells[index].type == nil {
            cells[index] = CraftingGridCell(type: type, count: count)
            return true
        }
        guard cells[index].type == type else { return false }
        cells[index].count += count
        return true
    }

    /// Empties one cell and returns what was in it (for returning to the
    /// hotbar — see InventoryView).
    @discardableResult
    func clearCell(_ index: Int) -> CraftingGridCell {
        guard cells.indices.contains(index) else { return CraftingGridCell(type: nil, count: 0) }
        let cell = cells[index]
        cells[index] = CraftingGridCell(type: nil, count: 0)
        return cell
    }

    /// The recipe the grid's current contents satisfy, or nil. Requires an
    /// exact type-set match (every type in the grid is part of the recipe,
    /// and every recipe ingredient is present in at least its required
    /// amount) — an unrelated extra item sitting in the grid means no match,
    /// same as a real crafting grid would refuse an unexpected ingredient.
    func matchingRecipe() -> CraftingRecipe? {
        let presentTypes = Set(cells.compactMap { $0.type })
        guard !presentTypes.isEmpty else { return nil }
        return CraftingRecipes.all.first { recipe in
            Set(recipe.ingredients.map { $0.type }) == presentTypes
                && recipe.ingredients.allSatisfy { totalCount(of: $0.type) >= $0.count }
        }
    }

    /// Consumes exactly one batch of a matched recipe's ingredients from the
    /// grid, spread across whichever cells hold that type.
    func consume(_ recipe: CraftingRecipe) {
        for ingredient in recipe.ingredients {
            var remaining = ingredient.count
            for index in cells.indices where remaining > 0 && cells[index].type == ingredient.type {
                let take = min(remaining, cells[index].count)
                cells[index].count -= take
                remaining -= take
                if cells[index].count == 0 {
                    cells[index].type = nil
                }
            }
        }
    }
}
