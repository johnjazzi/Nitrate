#include <metal_stdlib>
using namespace metal;

constexpr sampler linear_sampler(
    coord::normalized,
    filter::linear,
    address::clamp_to_edge
);

/// Pass 1: LUT (3D color lookup) + Halation + Glow
/// Fused into a single fragment shader per AD-6.
///
/// Input: Apple Log encoded image
/// Output: color-graded image with halation and glow

kernel void pass1_lut_halation_glow(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    texture3d<float, access::sample> lut   [[texture(2)]],
    constant float& halationStrength       [[buffer(0)]],
    constant float& glowStrength           [[buffer(1)]],
    constant float& outputContrast         [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }

    float4 color = input.read(gid);

    // The Resolve .cube assets are authored directly for normalized Apple Log 2
    // code values. Do not introduce an extra contrast curve before sampling.
    float3 lutSample = lut.sample(linear_sampler, color.rgb).rgb;

    // Soften the print contrast to match the reference look (post-LUT, pre-effects).
    lutSample = (lutSample - 0.5f) * outputContrast + 0.5f;

    // Halation: bloom in highlights from red channel scattering
    // Simulated by adding a warm diffusion to bright areas
    float luminance = dot(color.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float halationMask = smoothstep(0.7f, 0.95f, luminance);
    float3 halation = float3(1.0f, 0.4f, 0.2f) * halationStrength * halationMask;

    // Glow: soft light diffusion across the frame
    float3 glow = float3(0.1f, 0.05f, 0.0f) * glowStrength;

    float3 result = lutSample + halation + glow;

    output.write(float4(result, color.a), gid);
}