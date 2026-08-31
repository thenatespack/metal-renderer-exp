struct HotbarSlot {
    var type: VoxelType?
    /// -1 means infinite (creative). 0 with a type set shouldn't happen —
    /// hitting 0 clears `type` too, see Hotbar.consumeSelected.
    var count: Int
}

/// The player's full item storage: one slot per item type (7 raw materials
/// + 10 craftable ones — see CraftingRecipe). Only the first `hotbarSlotCount`
/// slots are the actual hotbar — wieldable, shown in the HUD bar, selected
/// with number keys 1...9/0 or shoulder buttons (edge-triggered, same
/// one-shot pattern as the third-person toggle). The remaining slots are
/// inventory-only overflow: visible and reachable in the Inventory screen
/// (see InventoryView), but not directly selectable — an item there has to
/// be equipped into the active hotbar slot first (InventoryView's
/// click-to-equip) before it can be placed. Creative starts every slot
/// filled with infinite blocks; survival starts empty and slots only fill up
/// as broken blocks are picked up (see Renderer's dropped-item handling) or
/// crafted (see craft(_:)).
final class Hotbar {
    private static let creativeLoadout: [VoxelType] = [
        .grass, .dirt, .stone, .sand, .wood, .leaves, .snow,
        .planks, .stoneBricks, .mudBricks, .packedSnow, .thatch,
        .polishedStone, .sandstone, .reinforcedPlanks, .packedDirt, .map,
    ]
    // 17 raw+crafted block/tool types (creativeLoadout) plus 4 animal-drop
    // items (bone, rawPork, rawMutton, rawChicken — see VoxelType) that
    // survival can pick up but creative doesn't start with: total storage
    // needs room for every distinct type a player could simultaneously hold,
    // not just creativeLoadout's own count.
    static let slotCount = 21
    /// Wieldable range: indices [0, hotbarSlotCount) — matches KeyCode.digits
    /// (1...9, 0) and what HotbarView draws in the HUD.
    static let hotbarSlotCount = 10

    private(set) var slots: [HotbarSlot]
    private(set) var selectedIndex = 0

    var selectedType: VoxelType? { slots[selectedIndex].type }

    init(gameMode: GameMode) {
        slots = Array(repeating: HotbarSlot(type: nil, count: 0), count: Self.slotCount)
        reset(for: gameMode)
    }

    func reset(for mode: GameMode) {
        switch mode {
        case .creative:
            slots = Self.creativeLoadout.map { HotbarSlot(type: $0, count: -1) }
        case .survival:
            slots = Array(repeating: HotbarSlot(type: nil, count: 0), count: Self.slotCount)
        }
    }

    func update(input: InputController) {
        for (index, key) in KeyCode.digits.enumerated() where index < slots.count {
            if input.consumeKeyPress(key) {
                selectedIndex = index
            }
        }
    }

    /// Shoulder-button hotbar navigation (see GameControllerManager) — wraps
    /// around in either direction, confined to the wieldable hotbar range
    /// same as digit-key selection (inventory-only overflow slots aren't
    /// reachable this way either).
    func cycle(by delta: Int) {
        let count = Self.hotbarSlotCount
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    /// Inventory click-to-equip (see InventoryView): swaps an inventory-only
    /// overflow slot's contents into the currently selected hotbar slot, so
    /// an item that overflowed past the wieldable range can still be
    /// equipped and placed. No-op if `index` is already within that range.
    func swapIntoSelectedHotbarSlot(from index: Int) {
        guard index >= Self.hotbarSlotCount, slots.indices.contains(index) else { return }
        slots.swapAt(index, selectedIndex)
    }

    /// Adds one block to a matching slot, or the first empty slot. Returns
    /// false if there's no room (every slot full of a different type) — the
    /// item is simply not picked up in that case.
    @discardableResult
    func addItem(_ type: VoxelType) -> Bool {
        if let index = slots.firstIndex(where: { $0.type == type }) {
            slots[index].count += 1
            return true
        }
        if let index = slots.firstIndex(where: { $0.type == nil }) {
            slots[index] = HotbarSlot(type: type, count: 1)
            return true
        }
        return false
    }

    @discardableResult
    func addItems(_ type: VoxelType, count: Int) -> Bool {
        var allFit = true
        for _ in 0..<count where !addItem(type) { allFit = false }
        return allFit
    }

    /// Consumes one of the selected slot (survival placing). No-op for
    /// creative's infinite (-1) slots.
    func consumeSelected() {
        guard slots[selectedIndex].count > 0 else { return }
        slots[selectedIndex].count -= 1
        if slots[selectedIndex].count == 0 {
            slots[selectedIndex].type = nil
        }
    }

    /// How many of `type` are held — Int.max for creative's infinite (-1)
    /// slots, so a >= comparison against a recipe's required count always
    /// passes without needing to special-case creative mode at the call site.
    func count(of type: VoxelType) -> Int {
        guard let slot = slots.first(where: { $0.type == type }) else { return 0 }
        return slot.count < 0 ? Int.max : slot.count
    }

    func hasIngredients(for recipe: CraftingRecipe) -> Bool {
        recipe.ingredients.allSatisfy { count(of: $0.type) >= $0.count }
    }

    /// Removes up to `count` of `type` from the hotbar (there's at most one
    /// slot per type, per addItem's stacking rule) — used to move items into
    /// CraftingGrid by dragging or via a recipe's auto-fill. Returns how many
    /// were actually removed, which may be less than requested. Infinite
    /// (-1) creative slots aren't decremented; dragging from one is a free
    /// copy, matching creative's "unlimited materials" model elsewhere.
    @discardableResult
    func remove(_ type: VoxelType, count: Int) -> Int {
        guard let index = slots.firstIndex(where: { $0.type == type }) else { return 0 }
        if slots[index].count < 0 { return count }
        let removed = min(count, slots[index].count)
        slots[index].count -= removed
        if slots[index].count == 0 {
            slots[index].type = nil
        }
        return removed
    }
}
