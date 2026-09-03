struct CraftingIngredient {
    let type: VoxelType
    let count: Int
}

struct CraftingRecipe {
    let ingredients: [CraftingIngredient]
    let resultType: VoxelType
    let resultCount: Int
    // Defaulted so the existing tier-1 recipe literals below don't need
    // touching — only the new tier-2 ones set this true. See InventoryView,
    // which dims/blocks these separately from a plain missing-ingredients lock.
    var requiresCraftingTable: Bool = false
}

enum CraftingRecipes {
    /// Tier-1 recipes, fitting a 4-column recipe-book grid (see InventoryView),
    /// deliberately varied: single-ingredient multipliers, 1:1 "refines",
    /// genuine multi-ingredient combines, and — for stoneBricks -> polished
    /// stone / planks+stone -> reinforced planks — recipes that consume a
    /// crafted intermediate rather than only raw materials, so the system
    /// isn't just "one level deep." Craftable anywhere, no table needed.
    private static let tierOne: [CraftingRecipe] = [
        CraftingRecipe(ingredients: [CraftingIngredient(type: .wood, count: 1)], resultType: .planks, resultCount: 4),
        CraftingRecipe(ingredients: [CraftingIngredient(type: .stone, count: 4)], resultType: .stoneBricks, resultCount: 4),
        CraftingRecipe(
            ingredients: [CraftingIngredient(type: .dirt, count: 2), CraftingIngredient(type: .sand, count: 2)],
            resultType: .mudBricks, resultCount: 2
        ),
        CraftingRecipe(ingredients: [CraftingIngredient(type: .snow, count: 4)], resultType: .packedSnow, resultCount: 2),
        CraftingRecipe(ingredients: [CraftingIngredient(type: .leaves, count: 4)], resultType: .thatch, resultCount: 2),
        CraftingRecipe(ingredients: [CraftingIngredient(type: .stoneBricks, count: 2)], resultType: .polishedStone, resultCount: 2),
        CraftingRecipe(ingredients: [CraftingIngredient(type: .sand, count: 4)], resultType: .sandstone, resultCount: 2),
        CraftingRecipe(ingredients: [CraftingIngredient(type: .dirt, count: 4)], resultType: .packedDirt, resultCount: 2),
        // Bootstraps tier two below — buildable anywhere like everything
        // else here, since a table can't itself require a table.
        CraftingRecipe(ingredients: [CraftingIngredient(type: .planks, count: 4)], resultType: .craftingTable, resultCount: 1),
    ]

    /// Tier-2 recipes: only craftable within Renderer.isNearCraftingTable's
    /// search radius of a placed .craftingTable block (see InventoryView,
    /// which locks these separately from a plain missing-ingredients dim).
    private static let tierTwo: [CraftingRecipe] = [
        CraftingRecipe(
            ingredients: [CraftingIngredient(type: .planks, count: 2), CraftingIngredient(type: .stone, count: 2)],
            resultType: .reinforcedPlanks, resultCount: 2, requiresCraftingTable: true
        ),
        CraftingRecipe(
            ingredients: [CraftingIngredient(type: .planks, count: 2), CraftingIngredient(type: .sand, count: 4)],
            resultType: .map, resultCount: 1, requiresCraftingTable: true
        ),
        // A genuine "deeper tier": consumes two already-crafted intermediates
        // rather than raw materials, demonstrating real progression.
        CraftingRecipe(
            ingredients: [CraftingIngredient(type: .reinforcedPlanks, count: 2), CraftingIngredient(type: .polishedStone, count: 2)],
            resultType: .stoneBricks, resultCount: 4, requiresCraftingTable: true
        ),
    ]

    static let all: [CraftingRecipe] = tierOne + tierTwo
}
