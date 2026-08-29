enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal   [[attribute(1)]];
        float3 color    [[attribute(2)]];
    };

    struct Uniforms {
        float4x4 modelMatrix;
        float4x4 viewProjectionMatrix;
        float3x3 normalMatrix;
        float3 lightDirection;
        float3 cameraPosition;
        float3 fogColor;
        float fogDistance;
        float time;
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
        float3 color;
    };

    // Cheap deterministic 3D->1D hash (Dave Hoskins-style) used to give each
    // block its own subtle, stable color variation instead of every block of
    // the same type reading as one flat, identical color.
    float hash13(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.yzx + 19.19);
        return fract((p.x + p.y) * p.z);
    }

    // Per-block tint, computed from the block's own voxel-space origin: `normal`
    // pulls a face's position half a unit inward before flooring, so all 6
    // faces of one block (which sit on that block's min OR max boundary along
    // whichever axis the face is perpendicular to) resolve to the same origin
    // and so the same tint — variation is per-block, not per-face. Uses the
    // pre-displacement local position/normal, so it stays stable even on
    // vertex functions that animate the final worldPosition afterward (water,
    // foliage), instead of jittering as those wave/sway.
    float3 tintedColor(float3 color, float3 localPosition, float3 localNormal) {
        float3 voxelOrigin = floor(localPosition - localNormal * 0.5);
        float variation = hash13(voxelOrigin);
        return color * (0.88 + 0.24 * variation);
    }

    vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);
        out.position = uniforms.viewProjectionMatrix * worldPosition;
        out.worldPosition = worldPosition.xyz;
        out.normal = normalize(uniforms.normalMatrix * in.normal);
        out.color = tintedColor(in.color, in.position, in.normal);
        return out;
    }

    float3 shadeAndFog(float3 baseColor, float3 normal, float3 worldPosition,
                        constant Uniforms &uniforms, float ambient) {
        float diffuse = max(dot(normal, -normalize(uniforms.lightDirection)), 0.0);
        float intensity = min(ambient + diffuse, 1.0);
        float3 shaded = baseColor * intensity;

        float dist = distance(worldPosition, uniforms.cameraPosition);
        float fogAmount = clamp(dist / uniforms.fogDistance, 0.0, 1.0);
        fogAmount = fogAmount * fogAmount;
        return mix(shaded, uniforms.fogColor, fogAmount);
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                   constant Uniforms &uniforms [[buffer(1)]]) {
        float3 finalColor = shadeAndFog(in.color, normalize(in.normal), in.worldPosition, uniforms, 0.25);
        return float4(finalColor, 1.0);
    }

    // Water surface: sits a little below the top of its block, gently bobs
    // with two overlapping sine waves, and adds a Blinn-Phong specular glint
    // so it reads as wet rather than a flat blue block. Only the top face
    // moves — the side faces at a shoreline (see Chunk/VoxelMesher) stay put
    // at the full block height — so the surface reads as recessed below the
    // shoreline's rim, and the wave amplitude is kept small enough that it
    // doesn't visibly pull away from those sides.
    vertex VertexOut vertex_water(VertexIn in [[stage_in]],
                                   constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);

        if (in.normal.y > 0.5) {
            float wave = sin(worldPosition.x * 0.5 + uniforms.time * 1.3) * 0.02
                       + sin(worldPosition.z * 0.4 + uniforms.time * 1.7) * 0.02;
            worldPosition.y += wave - 0.12;
        }

        out.position = uniforms.viewProjectionMatrix * worldPosition;
        out.worldPosition = worldPosition.xyz;
        out.normal = normalize(uniforms.normalMatrix * in.normal);
        out.color = tintedColor(in.color, in.position, in.normal);
        return out;
    }

    fragment float4 fragment_water(VertexOut in [[stage_in]],
                                    constant Uniforms &uniforms [[buffer(1)]]) {
        float3 normal = normalize(in.normal);
        float3 shaded = shadeAndFog(in.color, normal, in.worldPosition, uniforms, 0.35);

        float3 viewDir = normalize(uniforms.cameraPosition - in.worldPosition);
        float3 lightDir = -normalize(uniforms.lightDirection);
        float3 halfVec = normalize(lightDir + viewDir);
        float specular = pow(max(dot(normal, halfVec), 0.0), 48.0) * 0.6;
        shaded += specular;

        float dist = distance(in.worldPosition, uniforms.cameraPosition);
        float fogAmount = clamp(dist / uniforms.fogDistance, 0.0, 1.0);
        float alpha = mix(0.68, 1.0, fogAmount * fogAmount);

        return float4(shaded, alpha);
    }

    // Foliage (leaves): same lighting as static terrain but with a slightly
    // boosted ambient term (foliage reads better a touch brighter/"lusher"
    // than bare rock) and a gentle per-vertex wind sway in X/Z. Sway is
    // evaluated per-vertex rather than once per block, so the four corners of
    // a face drift very slightly out of sync — reads as a soft rustle rather
    // than the whole block rigidly rocking.
    vertex VertexOut vertex_foliage(VertexIn in [[stage_in]],
                                     constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);

        float sway = sin(worldPosition.x * 0.8 + uniforms.time * 1.8) * 0.05
                   + sin(worldPosition.z * 0.7 + uniforms.time * 2.3 + worldPosition.y) * 0.05;
        worldPosition.x += sway;
        worldPosition.z += sway * 0.7;

        out.position = uniforms.viewProjectionMatrix * worldPosition;
        out.worldPosition = worldPosition.xyz;
        out.normal = normalize(uniforms.normalMatrix * in.normal);
        out.color = tintedColor(in.color, in.position, in.normal);
        return out;
    }

    fragment float4 fragment_foliage(VertexOut in [[stage_in]],
                                      constant Uniforms &uniforms [[buffer(1)]]) {
        float3 finalColor = shadeAndFog(in.color, normalize(in.normal), in.worldPosition, uniforms, 0.32);
        return float4(finalColor, 1.0);
    }

    // Block highlight: an unlit, unfogged wireframe outline — no lighting or
    // distance fog, just a flat color, so it stays clearly visible against
    // whatever it's outlining regardless of time of day or draw distance.
    vertex VertexOut vertex_highlight(VertexIn in [[stage_in]],
                                       constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);
        out.position = uniforms.viewProjectionMatrix * worldPosition;
        out.worldPosition = worldPosition.xyz;
        out.normal = in.normal;
        out.color = in.color;
        return out;
    }

    fragment float4 fragment_highlight(VertexOut in [[stage_in]],
                                        constant Uniforms &uniforms [[buffer(1)]]) {
        return float4(in.color, 1.0);
    }
    """
}
