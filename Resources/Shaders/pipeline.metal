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

// Apple Log 2 (OCIO v2.6 AppleCameras.cpp constants, shared with
// PushPullExposure.swift and the LUT generator). Signed and unclamped at black:
// linear 0 sits at code 0.1505, and clamping there would lift every black pixel
// on a pull.
constant float kAppleLog2BlackOffset = -0.05641088f;
constant float kAppleLog2LinearKnee  = 0.01f;
constant float kAppleLog2Scale       = 47.28711236f;
constant float kAppleLog2Beta        = 0.00964052f;
constant float kAppleLog2Gamma       = 0.08550479f;
constant float kAppleLog2Delta       = 0.69336945f;
constant float kAppleLog2CodeKnee    = 0.20855532f; // scale * (knee - offset)^2

static inline float appleLog2Decode(float code) {
    if (!isfinite(code)) { return 0.0f; }
    if (code >= kAppleLog2CodeKnee) {
        return exp2((code - kAppleLog2Delta) / kAppleLog2Gamma) - kAppleLog2Beta;
    }
    if (code >= 0.0f) { return sqrt(code / kAppleLog2Scale) + kAppleLog2BlackOffset; }
    return kAppleLog2BlackOffset;
}

static inline float appleLog2Encode(float linear) {
    if (!isfinite(linear)) { return 0.0f; }
    float value = max(linear, kAppleLog2BlackOffset);
    if (value < kAppleLog2LinearKnee) {
        float shifted = value - kAppleLog2BlackOffset;
        return kAppleLog2Scale * shifted * shifted;
    }
    return kAppleLog2Delta + kAppleLog2Gamma * log2(value + kAppleLog2Beta);
}

kernel void pass1_lut_halation_glow(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    texture3d<float, access::sample> lut   [[texture(2)]],
    constant float& halationStrength       [[buffer(0)]],
    constant float& glowStrength           [[buffer(1)]],
    constant float& outputContrast         [[buffer(2)]],
    constant float& pushPullStops          [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }

    float4 color = input.read(gid);

    // Render-time push/pull: a scene-light gain, so it is applied in the linear
    // domain and re-encoded as Apple Log 2 before the cube is sampled. The cube
    // is authored for Apple Log 2 code values, so a code-domain multiply would
    // not be a stop — it would bend the curve instead of exposing it. Negative
    // stops pull (darker), positive push (brighter).
    if (pushPullStops != 0.0f) {
        float gain = exp2(pushPullStops);
        float3 exposed = float3(appleLog2Encode(appleLog2Decode(color.r) * gain),
                                appleLog2Encode(appleLog2Decode(color.g) * gain),
                                appleLog2Encode(appleLog2Decode(color.b) * gain));
        // Apple Log 2 is signed: codes under 0.1505 carry negative scene
        // values, and scaling those towards zero would move them against the
        // requested direction. Clamp so a pull only ever darkens and a push
        // only ever brightens.
        color.rgb = pushPullStops < 0.0f ? min(exposed, color.rgb) : max(exposed, color.rgb);
    }

    // The Resolve .cube assets are authored directly for normalized Apple Log 2
    // code values. Do not introduce an extra contrast curve before sampling.
    // A .cube domain knot i/(N-1) maps to the center of Metal texel i at
    // (i+0.5)/N. Convert domain coordinates to those normalized texel centers
    // before sampling so linear filtering interpolates the intended grid.
    float3 lutSize = float3(lut.get_width(), lut.get_height(), lut.get_depth());
    float3 lutCoordinates = (color.rgb * (lutSize - 1.0f) + 0.5f) / lutSize;
    float3 lutSample = lut.sample(linear_sampler, lutCoordinates).rgb;

    // Optional post-LUT contrast; shipped presets use 0.85.
    lutSample = (lutSample - 0.5f) * outputContrast + 0.5f;

    // Halation and glow are added by the spatial stage that follows.
    output.write(float4(lutSample, color.a), gid);
}
