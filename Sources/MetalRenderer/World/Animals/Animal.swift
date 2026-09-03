import simd

/// One wandering critter: picks a random direction every few seconds,
/// alternating between walking and standing still, turning smoothly to face
/// wherever it's currently headed. Stays on the ground via the same
/// groundHeight query the player uses, and refuses a step that would walk
/// into water or off too steep a drop rather than actually simulating
/// physics for it — good enough for something that just wanders in place.
final class Animal {
    let type: AnimalType
    var position: SIMD3<Float> // feet, world space
    private(set) var yaw: Float
    private(set) var isWalking = false
    /// Accumulated only while walking — feeds AnimalMesh's walk bob. Reset
    /// when idle so a critter doesn't "pop" mid-bob the instant it stops.
    private(set) var walkBobPhase: Float = 0

    private(set) var health: Int
    /// True the instant health hits 0; AnimalManager still keeps drawing/
    /// updating it (see deathTimer) for a beat so the death actually reads
    /// as one, rather than the critter vanishing the same frame it's killed.
    private(set) var isDead = false
    private var deathTimer: Float = 0
    /// True once deathTimer has run out — this is what AnimalManager
    /// actually removes on, not isDead itself.
    var readyToRemove: Bool { isDead && deathTimer <= 0 }
    /// Counts down from hitFlashDuration after a hit — AnimalMesh blends the
    /// whole critter toward red while this is nonzero, same idea as
    /// BlockHighlight's progress-driven color shift. Held at max for the
    /// entire death linger so a killed animal reads as "hit" the whole time
    /// it's fading out, not just for one brief flash.
    private(set) var hitFlashTimer: Float = 0
    /// 0...1, for AnimalMesh's red tint — normalizes hitFlashTimer against
    /// how long a flash actually lasts, so callers don't need to know that
    /// constant themselves.
    var hitFlashIntensity: Float { hitFlashTimer / Self.hitFlashDuration }
    private var knockback: SIMD3<Float> = .zero

    private var stateTimer: Float
    private var walkYaw: Float

    private static let maxHealth = 3
    private static let hitFlashDuration: Float = 0.2
    private static let deathLingerDuration: Float = 0.35
    private static let knockbackSpeed: Float = 4.5
    private static let knockbackDecay: Float = 0.88
    private static let turnSpeed: Float = 3.0 // rad/sec
    private static let maxStepHeightDelta: Float = 1.05 // steeper than this reads as a cliff, not a step

    init(type: AnimalType, position: SIMD3<Float>, yaw: Float) {
        self.type = type
        self.position = position
        self.yaw = yaw
        self.walkYaw = yaw
        self.stateTimer = Float.random(in: 0.5...3)
        self.health = Self.maxHealth
    }

    /// Called when the player attacks this animal (see Renderer.attackTargetedAnimal).
    /// `awayFromPlayer` should already be flattened to the horizontal plane.
    func hit(awayFromPlayer direction: SIMD2<Float>) {
        guard !isDead else { return }
        health -= 1
        hitFlashTimer = Self.hitFlashDuration
        knockback = SIMD3<Float>(direction.x, 0, direction.y) * Self.knockbackSpeed
        if health <= 0 {
            isDead = true
            deathTimer = Self.deathLingerDuration
            isWalking = false
            return
        }
        // Interrupt whatever it was doing — a stunned beat before it decides
        // to flee/wander again reads better than seamlessly continuing.
        isWalking = false
        stateTimer = min(stateTimer, 0.3)
    }

    /// `waterSurfaceHeight` mirrors Renderer's own — nil where the column is
    /// dry, matching exactly where the player would find water too.
    func update(deltaTime: Float, groundHeight: (Float, Float) -> Float, waterSurfaceHeight: (Float, Float) -> Float?) {
        if isDead {
            deathTimer = max(0, deathTimer - deltaTime)
            hitFlashTimer = Self.hitFlashDuration // stay flashed red the whole linger
            return // no more AI/movement once dead — just sits there fading out
        }

        if hitFlashTimer > 0 { hitFlashTimer = max(0, hitFlashTimer - deltaTime) }

        if knockback.x != 0 || knockback.z != 0 {
            let newX = position.x + knockback.x * deltaTime
            let newZ = position.z + knockback.z * deltaTime
            // Same cliff/water guard as normal walking — knockback shouldn't
            // be able to punt an animal into a lake or off a ledge.
            if waterSurfaceHeight(newX, newZ) == nil {
                let newGround = groundHeight(newX, newZ)
                if abs(newGround - position.y) <= Self.maxStepHeightDelta {
                    position.x = newX
                    position.z = newZ
                    position.y = newGround
                }
            }
            knockback *= Self.knockbackDecay
            if length(knockback) < 0.05 { knockback = .zero }
        }

        stateTimer -= deltaTime
        if stateTimer <= 0 {
            isWalking = Float.random(in: 0...1) < 0.7
            walkYaw = Float.random(in: 0..<(2 * .pi))
            stateTimer = Float.random(in: 2...5)
            if !isWalking { walkBobPhase = 0 }
        }

        guard isWalking else { return }

        var deltaAngle = walkYaw - yaw
        while deltaAngle > .pi { deltaAngle -= 2 * .pi }
        while deltaAngle < -.pi { deltaAngle += 2 * .pi }
        let maxTurn = Self.turnSpeed * deltaTime
        yaw += max(-maxTurn, min(maxTurn, deltaAngle))

        let forward = SIMD3<Float>(sin(yaw), 0, -cos(yaw)) // matches Camera.front's yaw convention
        let speed = type.walkSpeed
        let newX = position.x + forward.x * speed * deltaTime
        let newZ = position.z + forward.z * speed * deltaTime

        // Blocked by water or too big a height change (cliff/wall) — stop
        // and let the next stateTimer expiry pick a fresh direction, rather
        // than trying to path around it.
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
        walkBobPhase += deltaTime * speed * 4
    }
}
