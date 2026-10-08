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
    float grainSize;     // grain particle size (film stock specific)
    float padding;
};

/// Pass 2: 3D noise volume grain with temporal coherence (AD-9).
///
/// Samples a 128³ 3D noise volume. Each frame samples a z-slice at
/// z = frameIndex % 128, providing temporally coherent grain that
/// evolves frame-to-frame without flickering or static overlay artifacts.
///
/// Improvements over v1:
/// - Per-pixel hash offset kills visible 128px tiling
/// - Per-channel grain (R≠G≠B) for photorealistic film texture
/// - Blue channel gets 1.6× more grain (film chemistry reality)
/// - Grain fades toward pure black and pure white (film latitude)
/// - Subtractive grain model: grain darkens, doesn't just add noise
/// - High-frequency dither to prevent HEVC banding artifacts

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

    // --- Per-pixel hash offset to kill visible 128px tiling ---
    // Use a simple hash of pixel position + frame to scatter coordinates
    uint hash = (gid.x * 157u + gid.y * 631u + uniforms.frameIndex * 1103u);
    float offsetU = float(hash % 256u) / 256.0f;
    float offsetV = float((hash / 256u) % 256u) / 256.0f;

    float baseU = float(gid.x) / 128.0f;
    float baseV = float(gid.y) / 128.0f;
    float zSlice = float(uniforms.frameIndex % 128u) / 128.0f;

    // --- Per-channel grain sampling with different offsets ---
    // R channel: offset by (0, 0)
    float grainR = grainVol.sample(grain_sampler,
        float3(fract(baseU + offsetU * 0.37),
               fract(baseV + offsetV * 0.31), zSlice)).r;
    // G channel: offset by different hash-derived shift
    float grainG = grainVol.sample(grain_sampler,
        float3(fract(baseU + offsetU * 0.61 + 0.333),
               fract(baseV + offsetV * 0.53 + 0.167), zSlice)).r;
    // B channel: more grain, different offset
    float grainB = grainVol.sample(grain_sampler,
        float3(fract(baseU + offsetU * 0.83 + 0.667),
               fract(baseV + offsetV * 0.71 + 0.5), zSlice)).r;

    // Normalize to [-1, 1]
    grainR = (grainR - 0.5f) * 2.0f;
    grainG = (grainG - 0.5f) * 2.0f;
    grainB = (grainB - 0.5f) * 2.0f;

    // --- ISO-based intensity scaling ---
    // Reference: ISO 400 = baseline
    float intensity = uniforms.iso / 400.0f;
    float grainSize = uniforms.grainSize > 0.0f ? uniforms.grainSize : 1.0f;

    // Film-style grain: blue channel is ~1.6× grainier than red
    float3 grainScale = float3(1.0f, 1.3f, 1.6f) * intensity * 0.12f * grainSize;

    // --- Film latitude (grain fades near pure black and pure white) ---
    float luminance = dot(color.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    // Peak grain at midtones (0.3–0.6 luminance), fade at extremes
    float latitude = smoothstep(0.02f, 0.15f, luminance)
                   * (1.0f - smoothstep(0.75f, 0.95f, luminance));

    // --- Subtractive grain model ---
    // Real film grain is subtractive: silver halide crystals block light.
    // Darker areas of grain are more visible than brighter ones.
    // We darken mid-shadows more than we brighten highlights.
    float3 grainRgb = float3(grainR * grainScale.x,
                              grainG * grainScale.y,
                              grainB * grainScale.z) * latitude;

    // Higher weight on negative grain (dark specks) vs positive (bright specks)
    float3 result = color.rgb;
    result += grainRgb * 0.35f;  // additive component (small)
    // Subtractive: dark specks more prominent at mid-low luminance
    float3 subtractive = min(float3(0.0f), grainRgb) * 2.8f * (1.0f - luminance);
    result += subtractive;

    // --- High-frequency dither to prevent HEVC banding ---
    // 1-bit dither at the pixel level — imperceptible visually but
    // forces HEVC encoder to preserve detail instead of banding
    float dither = grainR * 0.004f;  // ~1/255 = 1 LSB in 8-bit
    result += dither;

    result = clamp(result, 0.0f, 1.0f);

    output.write(float4(result, color.a), gid);
}