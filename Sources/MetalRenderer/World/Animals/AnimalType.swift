/// The three wandering critters — see Animal/AnimalManager for behavior and
/// AnimalMesh for how each one is actually built out of boxes.
enum AnimalType: CaseIterable {
    case pig
    case sheep
    case chicken

    /// Blocks/second while walking — chickens scurry, sheep and pigs amble.
    var walkSpeed: Float {
        switch self {
        case .pig: return 1.1
        case .sheep: return 0.9
        case .chicken: return 1.4
        }
    }
}
