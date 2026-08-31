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
}
