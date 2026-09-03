import simd

/// One villager: the same wander state machine as Animal (random walk/idle
/// cycles, smooth turning, aborting a step into water or a >1.05 cliff — see
/// Animal.update's own comments) but tethered to a home position near its
/// house door instead of wandering freely — see `tetherRadius`. That's the
/// only behavioral difference from Animal. Villagers aren't combat entities
/// in this version (no health/death/knockback), just a deterministic
/// inhabitant with a fixed trade offer.
final class Villager {
    let homePosition: SIMD3<Float> // feet, world space — just outside the house door
    let tradeRecipe: TradeRecipe
    var position: SIMD3<Float> // feet, world space
    private(set) var yaw: Float
    private(set) var isWalking = false
    /// Accumulated only while walking — feeds VillagerMesh's walk bob, reset
    /// when idle so a villager doesn't "pop" mid-bob the instant it stops.
    private(set) var walkBobPhase: Float = 0

    private var stateTimer: Float
    private var walkYaw: Float

    private static let walkSpeed: Float = 0.8
    private static let turnSpeed: Float = 3.0 // rad/sec
    private static let maxStepHeightDelta: Float = 1.05
    private static let tetherRadius: Float = 8.0

    init(homePosition: SIMD3<Float>, yaw: Float, tradeRecipe: TradeRecipe) {
        self.homePosition = homePosition
        self.position = homePosition
        self.yaw = yaw
        self.walkYaw = yaw
        self.tradeRecipe = tradeRecipe
        self.stateTimer = Float.random(in: 0.5...3)
    }

    /// `waterSurfaceHeight` mirrors Renderer's/AnimalManager's own — nil
    /// where the column is dry.
    func update(deltaTime: Float, groundHeight: (Float, Float) -> Float, waterSurfaceHeight: (Float, Float) -> Float?) {
        stateTimer -= deltaTime
        if stateTimer <= 0 {
            isWalking = Float.random(in: 0...1) < 0.7
            let toHome = SIMD2<Float>(homePosition.x - position.x, homePosition.z - position.z)
            if length(toHome) > Self.tetherRadius {
                // Wandered past the tether — head back toward home instead
                // of picking a fully free direction. Matches Camera's yaw
                // convention (0 faces -Z, forward = (sin(yaw), -cos(yaw))).
                walkYaw = atan2(toHome.x, -toHome.y)
            } else {
                walkYaw = Float.random(in: 0..<(2 * .pi))
            }
            stateTimer = Float.random(in: 2...5)
            if !isWalking { walkBobPhase = 0 }
        }

        guard isWalking else { return }

        var deltaAngle = walkYaw - yaw
        while deltaAngle > .pi { deltaAngle -= 2 * .pi }
        while deltaAngle < -.pi { deltaAngle += 2 * .pi }
        let maxTurn = Self.turnSpeed * deltaTime
        yaw += max(-maxTurn, min(maxTurn, deltaAngle))

        let forward = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
        let newX = position.x + forward.x * Self.walkSpeed * deltaTime
        let newZ = position.z + forward.z * Self.walkSpeed * deltaTime

        guard waterSurfaceHeight(newX, newZ) == nil else {
            isWalking = false
            stateTimer = min(stateTimer, 0.5)
            return
        }
        let newGround = groundHeight(newX, newZ)
        guard abs(newGround - position.y) <= Self.maxStepHeightDelta else {
            isWalking = false
            stateTimer = min(stateTimer, 0.5)
            return
        }

        position.x = newX
        position.z = newZ
        position.y = newGround
        walkBobPhase += deltaTime * Self.walkSpeed * 4
    }
}
