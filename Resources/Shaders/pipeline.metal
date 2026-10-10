#include <metal_stdlib>
using namespace metal;

constexpr sampler linear_sampler(
    coord::normalized,
    filter::linear,
    address::clamp_to_edge
);

/// Pass 1: LUT (3D color lookup) + contrast.
///
/// Input: Apple Log encoded image
/// Output: color-graded image
///
/// Halation and glow used to be applied here as per-pixel terms. They are now
/// spatial (`spatial.metal`, story 1.4), so this pass only grades. The function
/// name and its binding layout are a versioned contract and are unchanged; the
/// `halationStrength` / `glowStrength` buffers are still bound for signature
/// stability but no longer read.

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

    // Soften the print contrast to match the reference look (post-LUT).
    lutSample = (lutSample - 0.5f) * outputContrast + 0.5f;

    // Halation and glow are added by the spatial stage that follows.
    output.write(float4(lutSample, color.a), gid);
}