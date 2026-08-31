struct CraftingIngredient {
    let type: VoxelType
    let count: Int
}

struct CraftingRecipe {
    let ingredients: [CraftingIngredient]
    let resultType: VoxelType
    let resultCount: Int
}

enum CraftingRecipes {
    /// Ten recipes, fitting a 4-column recipe-book grid (see InventoryView),
    /// deliberately varied: single-ingredient multipliers, 1:1 "refines",
    /// genuine multi-ingredient combines, and — for stoneBricks -> polished
    /// stone / planks+stone -> reinforced planks — recipes that consume a
    /// crafted intermediate rather than only raw materials, so the system
    /// isn't just "one level deep."
    static let all: [CraftingRecipe] = [
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
        CraftingRecipe(
            ingredients: [CraftingIngredient(type: .planks, count: 2), CraftingIngredient(type: .stone, count: 2)],
            resultType: .reinforcedPlanks, resultCount: 2
        ),
        CraftingRecipe(ingredients: [CraftingIngredient(type: .dirt, count: 4)], resultType: .packedDirt, resultCount: 2),
        CraftingRecipe(
            ingredients: [CraftingIngredient(type: .planks, count: 2), CraftingIngredient(type: .sand, count: 4)],
            resultType: .map, resultCount: 1
        ),
    ]
}
