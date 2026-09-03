import simd

/// Ensures every currently-loaded village has its quota of villagers present
/// — unlike AnimalManager's random-radius spawning, villagers are anchored
/// to fixed village locations (a pure function of world seed, same as the
/// structure itself), so a village's population is fully deterministic:
/// leaving and returning always finds the same villagers back (same
/// position/appearance/trade per house), not new random ones — even though
/// the actual Villager object instances get recreated on each visit rather
/// than persisted, mirroring how the village structure itself is never
/// actually "saved," just recomputed on demand.
final class VillagerManager {
    private struct VillageKey: Hashable { let centerX: Int; let centerZ: Int }

    private let villageGenerator: VillageGenerator
    private let groundHeight: (Float, Float) -> Float
    private let waterSurfaceHeight: (Float, Float) -> Float?

    private var activeVillages: [VillageKey: [Villager]] = [:]
    var villagers: [Villager] { activeVillages.values.flatMap { $0 } }

    // Roughly matches ChunkManager's default loadRadius(6)*chunkSize(16) —
    // a village only gets villagers once its chunks are actually streamed
    // in. Deactivation uses a wider radius than activation (hysteresis) so
    // a village hovering near the boundary doesn't flicker its population.
    private static let activationRadius: Float = 96
    private static let deactivationRadius: Float = 128

    init(villageGenerator: VillageGenerator, groundHeight: @escaping (Float, Float) -> Float, waterSurfaceHeight: @escaping (Float, Float) -> Float?) {
        self.villageGenerator = villageGenerator
        self.groundHeight = groundHeight
        self.waterSurfaceHeight = waterSurfaceHeight
    }

    func update(around playerPosition: SIMD3<Float>, deltaTime: Float) {
        let nearby = villageGenerator.nearbyVillageLayouts(
            x: Int(playerPosition.x.rounded(.down)), z: Int(playerPosition.z.rounded(.down))
        )
        for layout in nearby {
            let key = VillageKey(centerX: layout.centerX, centerZ: layout.centerZ)
            guard activeVillages[key] == nil else { continue }
            guard distanceSq(layout.centerX, layout.centerZ, to: playerPosition) <= Self.activationRadius * Self.activationRadius else { continue }
            activeVillages[key] = spawnVillagers(for: layout)
        }

        // Checked against every currently active village's own center, not
        // just `nearby` — that list only covers a 3x3 cell window around the
        // player's *current* position, which an active village could have
        // scrolled out of entirely since it was activated.
        let staleKeys = activeVillages.keys.filter {
            distanceSq($0.centerX, $0.centerZ, to: playerPosition) > Self.deactivationRadius * Self.deactivationRadius
        }
        for key in staleKeys { activeVillages.removeValue(forKey: key) }

        for villager in villagers {
            villager.update(deltaTime: deltaTime, groundHeight: groundHeight, waterSurfaceHeight: waterSurfaceHeight)
        }
    }

    private func distanceSq(_ x: Int, _ z: Int, to playerPosition: SIMD3<Float>) -> Float {
        let dx = Float(x) - playerPosition.x
        let dz = Float(z) - playerPosition.z
        return dx * dx + dz * dz
    }

    /// One villager per building, spawned just outside its door. Everything
    /// about a spawned villager (position, facing, trade offer) is a
    /// deterministic function of that building's own placement, so the same
    /// house always regenerates the "same" villager.
    private func spawnVillagers(for layout: VillageLayout) -> [Villager] {
        layout.buildings.map { building in
            let door = building.doorWorldPosition
            let spawnX = Float(door.x) + 0.5
            let spawnZ = Float(door.z) + 0.5
            let spawnY = groundHeight(spawnX, spawnZ)
            let recipeIndex = Self.deterministicIndex(building.originX, building.originZ, salt: 1, count: TradeRecipes.all.count)
            let yawDegrees = Self.deterministicIndex(building.originX, building.originZ, salt: 2, count: 360)
            return Villager(
                homePosition: SIMD3(spawnX, spawnY, spawnZ),
                yaw: Float(yawDegrees) * .pi / 180,
                tradeRecipe: TradeRecipes.all[recipeIndex]
            )
        }
    }

    /// Deterministic index in [0, count) from two world coordinates plus a
    /// salt — cheap integer mixing, same shape as VillageGenerator's own
    /// hash01 but purely for cosmetic/trade-offer variety, so it doesn't
    /// need the world seed itself (the coordinates are already
    /// seed-derived, via building placement).
    private static func deterministicIndex(_ a: Int, _ b: Int, salt: Int, count: Int) -> Int {
        var h = UInt64(bitPattern: Int64(a)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2AE3D27D4EB4F
        h ^= UInt64(bitPattern: Int64(salt)) &* 0x165667B19E3779F9
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
        h ^= h >> 31
        return Int(h % UInt64(count))
    }
}
