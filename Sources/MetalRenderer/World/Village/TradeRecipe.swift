/// A villager's fixed barter offer — a direct item-for-item exchange, no
/// currency. Reuses CraftingRecipe's own CraftingIngredient shape (type +
/// count) rather than inventing a new one.
struct TradeRecipe {
    let give: CraftingIngredient    // what the player pays
    let receive: CraftingIngredient // what the player gets
}

enum TradeRecipes {
    static let all: [TradeRecipe] = [
        TradeRecipe(give: CraftingIngredient(type: .wood, count: 5), receive: CraftingIngredient(type: .planks, count: 3)),
        TradeRecipe(give: CraftingIngredient(type: .stone, count: 5), receive: CraftingIngredient(type: .stoneBricks, count: 3)),
        TradeRecipe(give: CraftingIngredient(type: .rawPork, count: 2), receive: CraftingIngredient(type: .bone, count: 1)),
        TradeRecipe(give: CraftingIngredient(type: .sand, count: 6), receive: CraftingIngredient(type: .sandstone, count: 2)),
        TradeRecipe(give: CraftingIngredient(type: .dirt, count: 6), receive: CraftingIngredient(type: .packedDirt, count: 2)),
        TradeRecipe(give: CraftingIngredient(type: .leaves, count: 6), receive: CraftingIngredient(type: .thatch, count: 2)),
    ]
}
