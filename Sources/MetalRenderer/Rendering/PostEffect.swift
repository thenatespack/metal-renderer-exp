/// Full-screen post-process options, applied as a second pass over the
/// rendered scene (see Renderer.draw). Raw values are shared with the
/// fragment_post shader's switch in Shaders.swift — keep them in sync.
enum PostEffect: Int, CaseIterable {
    case none = 0
    case grayscale = 1
    case sepia = 2
    case invert = 3
    case vignette = 4

    var label: String {
        switch self {
        case .none: return "None"
        case .grayscale: return "Grayscale"
        case .sepia: return "Sepia"
        case .invert: return "Invert"
        case .vignette: return "Vignette"
        }
    }
}
