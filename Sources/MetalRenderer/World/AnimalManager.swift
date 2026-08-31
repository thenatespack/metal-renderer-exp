import simd

/// Spawns pigs/sheep/chickens on open grass around the player, updates their
/// wander AI every frame, and despawns ones left too far behind — a much
/// simpler cousin of ChunkManager's streaming (no persistence, no
/// background thread: spawning a handful of boxes is cheap enough to just
/// do inline on the main thread).
final class AnimalManager {
    private let terrainGenerator: TerrainGenerator
    private let groundHeight: (Float, Float) -> Float
    private let waterSurfaceHeight: (Float, Float) -> Float?

    private(set) var animals: [Animal] = []

    private let maxAnimals = 24
    private let spawnMinDistance: Float = 14
    private let spawnMaxDistance: Float = 36
    private let despawnDistance: Float = 64
    private let spawnInterval: Float = 1.5
    private var spawnCooldown: Float = 0

    init(terrainGenerator: TerrainGenerator, groundHeight: @escaping (Float, Float) -> Float, waterSurfaceHeight: @escaping (Float, Float) -> Float?) {
        self.terrainGenerator = terrainGenerator
        self.groundHeight = groundHeight
        self.waterSurfaceHeight = waterSurfaceHeight
    }

    func update(around playerPosition: SIMD3<Float>, deltaTime: Float) {
        // Dead animals are pulled out separately (see removeDeadAnimals),
        // not here — so they always get a chance for Renderer to spawn
        // their drops first, rather than possibly vanishing straight from
        // this distance check without one.
        let despawnDistanceSq = despawnDistance * despawnDistance
        animals.removeAll { animal in
            guard !animal.isDead else { return false }
            let dx = animal.position.x - playerPosition.x
            let dz = animal.position.z - playerPosition.z
            return dx * dx + dz * dz > despawnDistanceSq
        }

        spawnCooldown -= deltaTime
        if spawnCooldown <= 0 {
            spawnCooldown = spawnInterval
            trySpawn(around: playerPosition)
        }

        for animal in animals {
            animal.update(deltaTime: deltaTime, groundHeight: groundHeight, waterSurfaceHeight: waterSurfaceHeight)
        }
    }

    /// Pulls out (and removes) every animal that's finished its death
    /// linger — call once per frame, after update(), so Renderer can spawn
    /// drops for whatever's returned before it's actually gone.
    @discardableResult
    func removeDeadAnimals() -> [Animal] {
        var dead: [Animal] = []
        animals.removeAll { animal in
            guard animal.readyToRemove else { return false }
            dead.append(animal)
            return true
        }
        return dead
    }

    /// One attempt per call, not a whole batch — combined with spawnInterval
    /// this just means the population ambles up to maxAnimals over time
    /// rather than a pile of animals materializing in the same instant.
    private func trySpawn(around playerPosition: SIMD3<Float>) {
        guard animals.count < maxAnimals else { return }

        let angle = Float.random(in: 0..<(2 * .pi))
        let distance = Float.random(in: spawnMinDistance...spawnMaxDistance)
        let x = playerPosition.x + cos(angle) * distance
        let z = playerPosition.z + sin(angle) * distance
        let ix = Int(x.rounded(.down))
        let iz = Int(z.rounded(.down))

        let info = terrainGenerator.columnInfo(x: ix, z: iz)
        // Grass only (matches plains/taiga/forest — see Biome), and not a
        // cave/ravine mouth (see TerrainGenerator.isCarved, same check
        // Renderer's own spawn-column search uses) — an animal materializing
        // over an open pit would just fall right in.
        guard info.topBlock == .grass, !terrainGenerator.isCarved(x: ix, y: info.height, z: iz, surfaceHeight: info.height) else { return }

        let type = AnimalType.allCases.randomElement() ?? .pig
        let position = SIMD3<Float>(Float(ix) + 0.5, Float(info.height + 1), Float(iz) + 0.5)
        let yaw = Float.random(in: 0..<(2 * .pi))
        animals.append(Animal(type: type, position: position, yaw: yaw))
    }
}
