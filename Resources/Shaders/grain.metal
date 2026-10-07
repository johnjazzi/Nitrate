#include <metal_stdlib>
using namespace metal;

constexpr sampler grain_sampler(
    coord::normalized,
    filter::linear,
    address::repeat
);

/// Grain uniforms passed from CPU per frame (AD-9).
struct GrainUniforms {
    uint  frameIndex;   // Current frame number for z-slice selection
    float iso;           // ISO value scaling grain intensity
    float2 padding;
};

/// Pass 2: 3D noise volume grain with temporal coherence (AD-9).
///
/// Samples a 128³ 3D noise volume. Each frame samples a z-slice at
/// z = frameIndex % 128, providing temporally coherent grain that
/// evolves frame-to-frame without flickering or static overlay artifacts.
///
/// Grain intensity is scaled by the ISO slider — higher ISO = more grain.

kernel void pass2_grain(
    texture2d<float, access::read>  input      [[texture(0)]],
    texture2d<float, access::write> output     [[texture(1)]],
    texture3d<float, access::sample> grainVol  [[texture(2)]],
    constant GrainUniforms& uniforms           [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }

    float4 color = input.read(gid);

    // Compute 3D grain texture coordinates
    // x, y: spatial position (normalized, with tiling for small volumes)
    // z: temporal slice from frame index
    float u = fract(float(gid.x) / 128.0f);
    float v = fract(float(gid.y) / 128.0f);
    float zSlice = float(uniforms.frameIndex % 128u) / 128.0f;

    float3 grainCoord = float3(u, v, zSlice);

    // Sample grain volume — returns a value in [-1, 1] range
    float grainValue = grainVol.sample(grain_sampler, grainCoord).r;
    grainValue = (grainValue - 0.5f) * 2.0f; // normalize to [-1, 1]

    // Scale grain by ISO: higher ISO = stronger grain
    // Reference: ISO 400 = baseline, grain scales logarithmically
    float intensity = uniforms.iso / 400.0f;
    float grainIntensity = grainValue * intensity * 0.15f;

    // Apply grain to luminance channel for naturalistic look
    float luminance = dot(color.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float3 grainRGB = float3(grainIntensity);
    float3 result = color.rgb + (grainRGB * luminance);

    // Ensure valid output range
    result = clamp(result, 0.0f, 1.0f);

    output.write(float4(result, color.a), gid);
}