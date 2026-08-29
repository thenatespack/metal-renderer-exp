import simd

enum VoxelType: UInt8 {
    case air = 0
    case grass
    case dirt
    case stone
    case sand
    case snow
    case water
    case wood
    case leaves

    var isSolid: Bool { self != .air }

    var color: SIMD3<Float> {
        switch self {
        case .air:    return .zero
        case .grass:  return SIMD3<Float>(0.30, 0.55, 0.22)
        case .dirt:   return SIMD3<Float>(0.40, 0.28, 0.18)
        case .stone:  return SIMD3<Float>(0.45, 0.42, 0.40)
        case .sand:   return SIMD3<Float>(0.76, 0.70, 0.50)
        case .snow:   return SIMD3<Float>(0.95, 0.95, 0.97)
        case .water:  return SIMD3<Float>(0.15, 0.40, 0.75)
        case .wood:   return SIMD3<Float>(0.36, 0.25, 0.15)
        case .leaves: return SIMD3<Float>(0.16, 0.42, 0.14)
        }
    }
}
