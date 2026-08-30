import simd

struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD3<Float>
}

struct Uniforms {
    var modelMatrix: float4x4
    var viewProjectionMatrix: float4x4
    var normalMatrix: float3x3
    var lightDirection: SIMD3<Float>
    var cameraPosition: SIMD3<Float>
    var fogColor: SIMD3<Float>
    var fogDistance: Float
    var time: Float
}

/// Passed to fragment_post via setFragmentBytes — deliberately separate from
/// the main Uniforms buffer since the post-process pass doesn't need any of
/// the scene's own transform/lighting data.
struct PostEffectUniforms {
    var effect: Int32
}
