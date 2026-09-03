import Foundation

/// On-disk multi-world storage: `Worlds/<uuid>/meta.json` (name, seed, dates —
/// see WorldMeta) plus `Worlds/<uuid>/edits.json` (every block that world's
/// player has broken or placed) in its own subdirectory per world. Splitting
/// the two lets MainMenuView list every world cheaply without loading each
/// one's full edit history, same reasoning as BlockEdits' own column-range
/// snapshot.
///
/// Stateless on purpose (no cached listing) — this is only ever touched at
/// menu-navigation or save-point frequency, never per-frame, so there's no
/// benefit to caching worth the risk of it drifting from what's on disk.
enum WorldStore {
    private static var worldsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MetalRenderer", isDirectory: true).appendingPathComponent("Worlds", isDirectory: true)
    }

    private static func directory(for id: UUID) -> URL {
        worldsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func metaURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("meta.json") }
    private static func editsURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("edits.json") }

    /// Every world with readable metadata, most recently played first.
    /// Silently skips any subdirectory whose meta.json is missing/corrupt
    /// rather than failing the whole listing over one bad entry.
    static func listWorlds() -> [WorldMeta] {
        let ids = (try? FileManager.default.contentsOfDirectory(at: worldsDirectory, includingPropertiesForKeys: nil))?
            .compactMap { UUID(uuidString: $0.lastPathComponent) } ?? []
        let metas = ids.compactMap(readMeta)
        return metas.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    private static func readMeta(_ id: UUID) -> WorldMeta? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? JSONDecoder().decode(WorldMeta.self, from: data)
    }

    private static func writeMeta(_ meta: WorldMeta) {
        do {
            try FileManager.default.createDirectory(at: directory(for: meta.id), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(meta)
            try data.write(to: metaURL(meta.id), options: .atomic)
        } catch {
            print("[world] failed to write metadata for \(meta.id): \(error)")
        }
    }

    /// Creates a new world with no edits yet. `seed` defaults to a fresh
    /// random one (MainMenuView's seed field is optional, random when left
    /// blank) but can be pinned to reproduce a specific world.
    @discardableResult
    static func createWorld(name: String, seed: UInt64? = nil) -> WorldMeta {
        let now = Date()
        let meta = WorldMeta(id: UUID(), name: name, seed: seed ?? UInt64.random(in: 0...UInt64.max), createdAt: now, lastPlayedAt: now)
        writeMeta(meta)
        saveEdits([:], for: meta.id)
        return meta
    }

    /// Call when a world is opened for play — bumps lastPlayedAt so
    /// MainMenuView's list resurfaces it at the top next time.
    @discardableResult
    static func touchLastPlayed(_ id: UUID) -> WorldMeta? {
        guard var meta = readMeta(id) else { return nil }
        meta.lastPlayedAt = Date()
        writeMeta(meta)
        return meta
    }

    /// Called whenever PlayerVitals' health/hunger actually changes (see
    /// Renderer.persistVitals/saveNow) — same read-mutate-write shape as
    /// touchLastPlayed, since vitals live on the same small WorldMeta record
    /// rather than their own file.
    static func saveVitals(health: Int, hunger: Int, for id: UUID) {
        guard var meta = readMeta(id) else { return }
        meta.health = health
        meta.hunger = hunger
        writeMeta(meta)
    }

    static func loadEdits(for id: UUID) -> [BlockCoord: VoxelType] {
        guard let data = try? Data(contentsOf: editsURL(id)) else { return [:] }
        return (try? JSONDecoder().decode([BlockCoord: VoxelType].self, from: data)) ?? [:]
    }

    /// Blocking — call off the main thread (see Renderer.saveQueue) except at
    /// shutdown, where there's no next frame to let an async write finish on.
    static func saveEdits(_ edits: [BlockCoord: VoxelType], for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(edits)
            try data.write(to: editsURL(id), options: .atomic)
        } catch {
            print("[world] failed to write edits for \(id): \(error)")
        }
    }

    static func deleteWorld(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }
}
