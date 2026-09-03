/// The player's own health/hunger — survival mode only (see Renderer, which
/// skips calling update() entirely in creative). Mirrors Animal's shape (an
/// isolated small state machine with its own tunable constants) but simpler:
/// there's no attacker to knock the player back from, only self-inflicted
/// damage (falling, starving), so no hit-flash/knockback machinery is
/// needed here.
final class PlayerVitals {
    private(set) var health: Int
    private(set) var hunger: Int
    /// True the instant health hits 0 — Renderer reacts (toast + teleport to
    /// spawn) and calls respawn() to clear this, same frame or the next.
    private(set) var isDead = false

    private var hungerTimer: Float = 0
    private var regenTimer: Float = 0
    private var starveTimer: Float = 0

    static let maxHealth = 10
    static let maxHunger = 10
    /// Flat real-time drain, not distance/sprint-tracked — the simplest rule
    /// that still makes eating matter, without new PlayerController plumbing.
    private static let hungerDrainInterval: Float = 45
    /// Regen only kicks in once hunger is comfortably above empty, same idea
    /// as Minecraft's "well-fed" threshold — eating isn't just anti-starvation.
    private static let regenHungerThreshold = 6
    private static let regenInterval: Float = 4
    private static let starveInterval: Float = 6
    private static let foodRestoreAmount = 4
    /// Blocks of fall past this height start hurting; below it reads as a
    /// normal step/hop, matching maxStepHeight-ish scale elsewhere.
    static let safeFallDistance: Float = 3
    static let fallDamagePerBlock = 2

    init(health: Int?, hunger: Int?) {
        self.health = health ?? Self.maxHealth
        self.hunger = hunger ?? Self.maxHunger
    }

    /// `fallDamage` is already computed by the caller from PlayerController's
    /// lastFallDistance — this just applies it, same call each frame whether
    /// or not a landing actually happened (0 the rest of the time).
    func update(deltaTime: Float, fallDamage: Int) {
        guard !isDead else { return }

        if fallDamage > 0 {
            applyDamage(fallDamage)
            guard !isDead else { return }
        }

        hungerTimer += deltaTime
        if hungerTimer >= Self.hungerDrainInterval {
            hungerTimer -= Self.hungerDrainInterval
            hunger = max(0, hunger - 1)
        }

        if hunger == 0 {
            starveTimer += deltaTime
            if starveTimer >= Self.starveInterval {
                starveTimer = 0
                applyDamage(1)
            }
        } else {
            starveTimer = 0
        }

        if hunger >= Self.regenHungerThreshold && health < Self.maxHealth {
            regenTimer += deltaTime
            if regenTimer >= Self.regenInterval {
                regenTimer = 0
                health = min(Self.maxHealth, health + 1)
            }
        } else {
            regenTimer = 0
        }
    }

    private func applyDamage(_ amount: Int) {
        health = max(0, health - amount)
        if health == 0 { isDead = true }
    }

    /// Only the three raw meats are food — bone is a pure crafting material.
    /// Returns false (and does nothing) if `type` isn't food or hunger's
    /// already full, so the caller only consumes the hotbar item on success.
    @discardableResult
    func eat(_ type: VoxelType) -> Bool {
        switch type {
        case .rawPork, .rawMutton, .rawChicken:
            guard hunger < Self.maxHunger else { return false }
            hunger = min(Self.maxHunger, hunger + Self.foodRestoreAmount)
            return true
        default:
            return false
        }
    }

    func respawn() {
        health = Self.maxHealth
        hunger = Self.maxHunger
        isDead = false
        hungerTimer = 0
        regenTimer = 0
        starveTimer = 0
    }
}
