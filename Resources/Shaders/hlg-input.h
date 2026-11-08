#ifndef NITRATE_HLG_INPUT_H
#define NITRATE_HLG_INPUT_H
#include <metal_stdlib>
using namespace metal;

// Camera HLG: inverse BT.2100 OETF, NOT the display EOTF/inverse OOTF.
// Nominal inverse OETF is 0...1. House exposure normalization: 75% HLG
// diffuse white -> scene-linear 1.0 (scale 1 / inverseOETF(.75)).
// CAEDRMetadata's 0...12 unnormalized convention is NOT consumed here.
static inline float hlg_scene(float code) {
    float magnitude = abs(code);
    float value = magnitude <= 0.5f ? magnitude * magnitude / 3.0f
        : (exp((magnitude - 0.55991073f) / 0.17883277f) + 0.28466892f) / 12.0f;
    return copysign(value, code);
}
static inline float hlg_apple_log_encode(float value) {
    if (value <= -0.05641088f) return 0.0f;
    return value < 0.01f ? 47.28711236f * pow(value + 0.05641088f, 2.0f)
        : 0.69336945f + 0.08550479f * log2(value + 0.00964052f);
}
static inline float3 hlg_scene_to_apple_wide_gamut(float3 scene) {
    // BT.2020 D65 -> Apple Wide Gamut D65. Derived from chromaticities in
    // the vendored OCIO AppleCameras.cpp (no chromatic adaptation needed).
    float3 awg = float3(dot(scene, float3(.9750428995f, -.0768564900f, .1018135904f)),
                        dot(scene, float3(.0008445448f, .8615375131f, .1376179421f)),
                        dot(scene, float3(.0198781607f, .0492425795f, .9308792597f)));
    return awg;
}
static inline float3 hlg_to_lut_input(float3 code) {
    float3 scene = float3(hlg_scene(code.r), hlg_scene(code.g), hlg_scene(code.b)) * 3.7741181275f;
    float3 awg = hlg_scene_to_apple_wide_gamut(scene);
    return float3(hlg_apple_log_encode(awg.r), hlg_apple_log_encode(awg.g), hlg_apple_log_encode(awg.b));
}
#endif
