import Foundation

/// Small, cheap-to-list metadata for one saved world — kept separate from its
/// (potentially large) block edits so MainMenuView can list every world
/// without loading each one's full edit history (see WorldStore).
struct WorldMeta: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let seed: UInt64
    let createdAt: Date
    var lastPlayedAt: Date
    // Optional (not defaulted) so meta.json written before PlayerVitals existed
    // still decodes: a missing key becomes nil here rather than a decode
    // failure. nil means "no saved vitals yet" — treated as full health/hunger.
    var health: Int?
    var hunger: Int?
}
