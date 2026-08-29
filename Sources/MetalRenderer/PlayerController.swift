import simd

/// Walking + gravity on top of Camera: mouse-look sets yaw/pitch as before,
/// but WASD now moves along the flat (yaw-only) ground plane instead of the
/// full look direction, so pitching the camera up/down doesn't push you into
/// the sky or the ground. Vertical position is driven by gravity and clamped
/// to the terrain height sampled fresh every frame at the player's (x, z),
/// so walking follows slopes/steps, and jumping lifts off it.
///
/// Horizontal movement is collision-checked against that same height sample:
/// a destination column whose ground is only a little higher (up to
/// `maxStepHeight`) is treated as a walkable step and auto-climbed by the
/// normal vertical snap below; anything taller — a cliff, a mountainside —
/// blocks that step instead of walking through it. Diagonal moves that are
/// blocked retry each axis alone, so bumping into a wall at an angle slides
/// you along it rather than just stopping dead.
///
/// Ground height alone can't see vertical obstacles that don't affect terrain
/// elevation — a tree's trunk or canopy standing on flat ground, say — so
/// `isObstructed` is a second, independent check for those.
///
/// `waterSurfaceHeight` marks which columns are wet. Below that surface and
/// above the real lakebed (`groundHeight`, which is the true unclamped
/// terrain surface — swimming needs to know how deep the water actually is,
/// not just that it exists), normal gravity is replaced with buoyancy: Space
/// swims up, releasing it lets you sink gently, and horizontal speed is
/// reduced. Swimming up through the surface, or walking off a bank into air
/// above water, both fall straight out of that branch back into normal
/// gravity/ground-snap — there's no special-cased transition, each frame just
/// re-checks where the player's feet are relative to ground and water.
///
/// In third person, `isSolidAt` (a general point query) is also used each
/// frame to shorten the camera's pullback from the player when terrain or a
/// tree sits between them, so it stops short of clipping through instead of
/// swinging past into solid geometry.
final class PlayerController {
    let camera: Camera
    private let groundHeight: (Float, Float) -> Float
    private let waterSurfaceHeight: (Float, Float) -> Float?
    private let isObstructed: (Float, Float) -> Bool
    private let isSolidAt: (Float, Float, Float) -> Bool

    var eyeHeight: Float = 1.75
    var walkSpeed: Float = 6
    var sprintMultiplier: Float = 1.8
    var jumpSpeed: Float = 8
    var gravity: Float = 22
    var maxStepHeight: Float = 1.1
    var thirdPersonCameraStep: Float = 0.15
    var minThirdPersonPullback: Float = 0.15

    var swimSpeedMultiplier: Float = 0.6
    var swimUpSpeed: Float = 3.5
    var swimSinkSpeed: Float = 1.2
    var swimAcceleration: Float = 10

    private var verticalVelocity: Float = 0
    private(set) var isGrounded = false
    private(set) var isSwimming = false

    init(
        camera: Camera,
        groundHeight: @escaping (Float, Float) -> Float,
        waterSurfaceHeight: @escaping (Float, Float) -> Float?,
        isObstructed: @escaping (Float, Float) -> Bool,
        isSolidAt: @escaping (Float, Float, Float) -> Bool
    ) {
        self.camera = camera
        self.groundHeight = groundHeight
        self.waterSurfaceHeight = waterSurfaceHeight
        self.isObstructed = isObstructed
        self.isSolidAt = isSolidAt
    }

    func update(input: InputController, deltaTime: Float) {
        if input.consumeKeyPress(KeyCode.c) {
            camera.isThirdPerson.toggle()
        }

        let (dx, dy) = input.consumeMouseDelta()
        if dx != 0 || dy != 0 {
            camera.yaw += dx * camera.lookSensitivity
            camera.pitch -= dy * camera.lookSensitivity
            let limit = Float.pi / 2 - 0.01
            camera.pitch = Math.clamp(camera.pitch, -limit, limit)
        }

        let feetY = camera.position.y - eyeHeight
        let waterTop = waterSurfaceHeight(camera.position.x, camera.position.z)
        isSwimming = (waterTop.map { feetY < $0 }) ?? false

        let flatFront = SIMD3<Float>(sin(camera.yaw), 0, -cos(camera.yaw))
        let flatRight = SIMD3<Float>(cos(camera.yaw), 0, sin(camera.yaw))

        let keys = input.pressedKeys
        var moveDir = SIMD3<Float>(repeating: 0)
        if keys.contains(KeyCode.w) { moveDir += flatFront }
        if keys.contains(KeyCode.s) { moveDir -= flatFront }
        if keys.contains(KeyCode.d) { moveDir += flatRight }
        if keys.contains(KeyCode.a) { moveDir -= flatRight }

        if moveDir != SIMD3<Float>(repeating: 0) {
            moveDir = normalize(moveDir)
            var speed = walkSpeed * (input.shiftPressed ? sprintMultiplier : 1)
            if isSwimming { speed *= swimSpeedMultiplier }
            let currentGround = groundHeight(camera.position.x, camera.position.z)

            func tryMove(_ dx: Float, _ dz: Float) -> Bool {
                let newX = camera.position.x + dx
                let newZ = camera.position.z + dz
                // Underwater, stepping toward deeper/shallower ground is just
                // swimming, not climbing — only the dry-land step limit applies.
                guard isSwimming || groundHeight(newX, newZ) - currentGround <= maxStepHeight else { return false }
                guard !isObstructed(newX, newZ) else { return false }
                camera.position.x = newX
                camera.position.z = newZ
                return true
            }

            let dx = moveDir.x * speed * deltaTime
            let dz = moveDir.z * speed * deltaTime
            if !tryMove(dx, dz) {
                if !tryMove(dx, 0) {
                    _ = tryMove(0, dz)
                }
            }
        }

        if isSwimming {
            if keys.contains(KeyCode.space) {
                verticalVelocity = min(verticalVelocity + swimAcceleration * deltaTime, swimUpSpeed)
            } else {
                verticalVelocity = max(verticalVelocity - swimAcceleration * deltaTime, -swimSinkSpeed)
            }
            camera.position.y += verticalVelocity * deltaTime

            let floorHeight = groundHeight(camera.position.x, camera.position.z) + eyeHeight
            if camera.position.y <= floorHeight {
                camera.position.y = floorHeight
                verticalVelocity = 0
                isGrounded = true
            } else {
                isGrounded = false
            }
        } else {
            if keys.contains(KeyCode.space), isGrounded {
                verticalVelocity = jumpSpeed
                isGrounded = false
            }

            verticalVelocity -= gravity * deltaTime
            camera.position.y += verticalVelocity * deltaTime

            let standingHeight = groundHeight(camera.position.x, camera.position.z) + eyeHeight
            if camera.position.y <= standingHeight {
                camera.position.y = standingHeight
                verticalVelocity = 0
                isGrounded = true
            } else {
                isGrounded = false
            }
        }

        camera.thirdPersonPullback = camera.isThirdPerson ? resolveThirdPersonPullback() : 1
    }

    /// Marches from the player out along the third-person offset direction,
    /// stopping just short of the first solid point hit. Returns a 0...1
    /// fraction of the full offset that's safe to use.
    private func resolveThirdPersonPullback() -> Float {
        let offset = -camera.front * camera.thirdPersonDistance + SIMD3<Float>(0, camera.thirdPersonHeight, 0)
        let fullDistance = length(offset)
        guard fullDistance > 0.001 else { return 1 }
        let direction = offset / fullDistance

        var traveled: Float = thirdPersonCameraStep
        while traveled < fullDistance {
            let sample = camera.position + direction * traveled
            if isSolidAt(sample.x, sample.y, sample.z) {
                return max(minThirdPersonPullback, (traveled - thirdPersonCameraStep) / fullDistance)
            }
            traveled += thirdPersonCameraStep
        }
        return 1
    }
}
