import simd

/// Pure view state — position, facing, and the derived view matrix. Movement
/// (walking, gravity, jumping, mouse-look) lives in PlayerController, which
/// drives this each frame.
///
/// `position` is always the player's own anchor point (first-person eye
/// height). Third person doesn't move that — it only changes where the
/// *camera* sits: pulled back behind and above the player, still looking at
/// them, via `eyePosition`/`viewMatrix`. That keeps ground collision and
/// everything else that reads `position` unaffected by the view mode.
final class Camera {
    var position: SIMD3<Float>
    var yaw: Float
    var pitch: Float
    var lookSensitivity: Float = 0.0025

    var isThirdPerson = false
    var thirdPersonDistance: Float = 4.5
    var thirdPersonHeight: Float = 1.3
    /// 1 = fully pulled back to (thirdPersonDistance, thirdPersonHeight); 0 =
    /// right at the player. PlayerController shortens this each frame when
    /// terrain/trees are in the way, so the camera stops before it would clip
    /// through them instead of swinging past into solid geometry.
    var thirdPersonPullback: Float = 1

    init(position: SIMD3<Float>, yaw: Float = 0, pitch: Float = 0) {
        self.position = position
        self.yaw = yaw
        self.pitch = pitch
    }

    var front: SIMD3<Float> {
        SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))
    }

    var eyePosition: SIMD3<Float> {
        guard isThirdPerson else { return position }
        let offset = -front * thirdPersonDistance + SIMD3<Float>(0, thirdPersonHeight, 0)
        return position + offset * thirdPersonPullback
    }

    var viewMatrix: float4x4 {
        let target = isThirdPerson ? position : position + front
        return Math.lookAt(eye: eyePosition, center: target, up: SIMD3<Float>(0, 1, 0))
    }
}
