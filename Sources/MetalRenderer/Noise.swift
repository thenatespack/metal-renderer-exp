import Foundation

/// Deterministic, seedable PRNG (SplitMix64) used to shuffle the Perlin permutation table.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Classic Perlin gradient noise in 2D, plus fractal Brownian motion (fbm) for terrain-like detail.
final class PerlinNoise {
    private let permutation: [Int]

    init(seed: UInt64) {
        var table = Array(0..<256)
        var rng = SplitMix64(seed: seed)
        table.shuffle(using: &rng)
        permutation = table + table
    }

    private func fade(_ t: Float) -> Float {
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + t * (b - a)
    }

    private func grad(_ hash: Int, _ x: Float, _ y: Float) -> Float {
        let h = hash & 7
        let u = h < 4 ? x : y
        let v = h < 4 ? y : x
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }

    func noise(x: Float, y: Float) -> Float {
        let xi = Int(floor(x)) & 255
        let yi = Int(floor(y)) & 255
        let xf = x - floor(x)
        let yf = y - floor(y)
        let u = fade(xf)
        let v = fade(yf)

        let aa = permutation[permutation[xi] + yi]
        let ab = permutation[permutation[xi] + yi + 1]
        let ba = permutation[permutation[xi + 1] + yi]
        let bb = permutation[permutation[xi + 1] + yi + 1]

        let x1 = lerp(grad(aa, xf, yf), grad(ba, xf - 1, yf), u)
        let x2 = lerp(grad(ab, xf, yf - 1), grad(bb, xf - 1, yf - 1), u)
        return lerp(x1, x2, v)
    }

    /// Sum of several octaves of noise; result stays roughly in [-1, 1].
    func fbm(x: Float, y: Float, octaves: Int, persistence: Float = 0.5, lacunarity: Float = 2.0) -> Float {
        var total: Float = 0
        var frequency: Float = 1
        var amplitude: Float = 1
        var maxValue: Float = 0

        for _ in 0..<octaves {
            total += noise(x: x * frequency, y: y * frequency) * amplitude
            maxValue += amplitude
            amplitude *= persistence
            frequency *= lacunarity
        }

        return total / maxValue
    }
}
