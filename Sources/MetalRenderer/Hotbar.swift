/// The player's selection of which block type to place, cycled with the
/// number keys. Consumed once per frame from InputController's
/// edge-triggered key presses — same one-shot-toggle pattern as the
/// third-person camera key.
final class Hotbar {
    let items: [VoxelType] = [.grass, .dirt, .stone, .sand, .wood, .leaves, .snow]
    private(set) var selectedIndex = 0

    var selectedType: VoxelType { items[selectedIndex] }

    func update(input: InputController) {
        for (index, key) in KeyCode.digits.enumerated() where index < items.count {
            if input.consumeKeyPress(key) {
                selectedIndex = index
            }
        }
    }
}
