/// A biome is just a height profile + block palette, picked per-column from
/// temperature/moisture noise. Discrete (no blending), so borders are crisp,
/// which reads fine at voxel scale.
enum Biome {
    case desert
    case tundra
    case plains
    case taiga
    case forest

    var baseHeight: Float {
        switch self {
        case .desert:  return 9
        case .tundra:  return 11
        case .plains:  return 12
        case .taiga:   return 13
        case .forest:  return 13
        }
    }

    var amplitude: Float {
        switch self {
        case .desert:  return 5
        case .tundra:  return 5
        case .plains:  return 7
        case .taiga:   return 8
        case .forest:  return 9
        }
    }

    var surfaceBlock: VoxelType {
        switch self {
        case .desert:  return .sand
        case .tundra:  return .snow
        case .plains, .taiga, .forest: return .grass
        }
    }

    var subsurfaceBlock: VoxelType {
        switch self {
        case .desert: return .sand
        default:      return .dirt
        }
    }

    /// Fraction of eligible (grass-topped) columns in this biome that grow a tree.
    var treeDensity: Float {
        switch self {
        case .forest:  return 0.5
        case .taiga:   return 0.35
        case .plains:  return 0.05
        case .desert, .tundra: return 0
        }
    }

    /// Selects a biome from normalized (0...1) temperature and moisture, à la a
    /// Whittaker diagram: cold/hot bands crossed with dry/wet.
    static func select(temperature: Float, moisture: Float) -> Biome {
        let cold = temperature < 0.35
        let hot = temperature >= 0.65
        let wet = moisture >= 0.5

        if cold { return wet ? .taiga : .tundra }
        if hot { return wet ? .forest : .desert }
        return wet ? .forest : .plains
    }
}
