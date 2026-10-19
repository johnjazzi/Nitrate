#include <metal_stdlib>
using namespace metal;

constexpr sampler spatial_linear_sampler(
    coord::normalized,
    filter::linear,
    address::clamp_to_edge
);

/// Spatial halation + glow (epic story 1.4).
///
/// The previous implementation was purely per-pixel: it added a warm term
/// scaled by the pixel's own luma, so a highlight could never bleed *neighbourhood*
/// information into surrounding pixels, and glow was a constant frame-wide lift.
/// This stage extracts a highlight mask once, blurs it separably, then composites
/// the blurred mask back over the graded image. Diffusion is now genuinely
/// spatial: bright areas bleed warm light into their surroundings the way light
/// scattering inside film does.
///
/// The mask is built and blurred at HALF resolution. Halation and glow are
/// low-frequency by nature, so half-res blurring is visually equivalent while
/// cutting the scratch texture cost (and bandwidth) by 4x at 4K.
///
/// GLOW is unchanged by the physical-halation work: `spatial_mask` and
/// `spatial_composite` below still read the graded image and still apply the
/// stock's tint, so the optical-filter bloom keeps exactly the look it had.
/// Halation no longer uses them — see `spatial_halation_mask` and
/// `spatial_halation_composite`.

/// Rec.709 luma of the post-LUT graded image.
static inline float spatial_luma(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

/// Extract a highlight mask from the source image.
///
/// Reads the full-resolution graded source but writes a
/// half-resolution, UNTINTED mask (the highlight weight in all three channels).
/// Keeping it untinted lets one mask drive both the narrow halation and the
/// wide glow, which use different colour casts, so the expensive blur is only
/// paid for once. The tint is applied at composite time.
kernel void spatial_mask(
    texture2d<float, access::read>  source [[texture(0)]],
    texture2d<float, access::write> mask   [[texture(1)]],
    constant float& thresholdLow           [[buffer(0)]],
    constant float& thresholdHigh          [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) {
        return;
    }

    // 2x2 box average of the full-res source into this half-res texel.
    float3 sum = float3(0.0f);
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            uint2 src = gid * 2 + uint2(dx, dy);
            if (src.x < source.get_width() && src.y < source.get_height()) {
                sum += source.read(src).rgb;
            }
        }
    }
    float3 color = sum * 0.25f;

    // Highlight weight from the source luma: only genuine highlights contribute.
    float highlight = smoothstep(thresholdLow, thresholdHigh, spatial_luma(color));

    mask.write(float4(highlight, highlight, highlight, 1.0f), gid);
}

// Diffusion is encoded by SpatialEffectsStage using MPSImageGaussianBlur.
// Do not restore sparse radius-scaled taps: they create detached source copies.

/// Composite a blurred mask back over the graded image.
///
/// `strength` carries the stock's halation or glow value and `tint` its colour
/// cast, so this is a plain additive screen-in of tinted light with the image's
/// luminance modulating the effect so shadows stay clean.
///
/// Halation is a RING, not a filled disc: light reflects off the film base and
/// re-exposes the emulsion *around* the source, not on top of it. The blurred
/// mask is therefore reduced by the source's own highlight contribution so the
/// added light lands in the tail outside the boundary. `ringTailBalance` mixes
/// between the pure ring (1) and the raw blurred mask — a softer glow — (0);
/// glow passes 0 so it stays a plain bloom rather than acquiring a hole.
kernel void spatial_composite(
    texture2d<float, access::read>  graded   [[texture(0)]],
    texture2d<float, access::sample> mask     [[texture(1)]],
    texture2d<float, access::write> output    [[texture(2)]],
    constant float& strength                  [[buffer(0)]],
    constant float& shadowFloor               [[buffer(1)]],
    constant float3& tint                     [[buffer(2)]],
    constant float& ringTailBalance           [[buffer(3)]],
    constant float& thresholdLow              [[buffer(4)]],
    constant float& thresholdHigh             [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float4 base = graded.read(gid);

    // `gid` is in graded/output space, so normalize by the OUTPUT size. The mask
    // is half resolution; normalizing by the mask's own size here would double
    // the sampling coordinate and miss the diffusion entirely.
    float2 size = float2(graded.get_width(), graded.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;
    float spread = mask.sample(spatial_linear_sampler, uv).r;

    // The source's own highlight contribution, recomputed at full resolution
    // with the same window the mask kernel used. Subtracting it from the blurred
    // mask empties the centre of the highlight and leaves the tail lit — a ring.
    float sourceHighlight = smoothstep(thresholdLow, thresholdHigh, spatial_luma(base.rgb));
    float ring = max(0.0f, spread - sourceHighlight);
    float contribution = mix(spread, ring, ringTailBalance);

    // Fade the added light out of the deepest shadows so halation and glow
    // never lift the black point (the old constant glow term did exactly that).
    float luminance = spatial_luma(base.rgb);
    float shadowWeight = smoothstep(0.0f, shadowFloor, luminance);

    float3 result = base.rgb + tint * contribution * strength * shadowWeight;

    output.write(float4(result, base.a), gid);
}

// ===========================================================================
// Physical halation
// ===========================================================================
//
// Halation is light crossing the emulsion, reflecting off the film base or the
// anti-halation backing, and re-exposing the surrounding emulsion. Two things
// follow, and the implementation above gets neither:
//
//  1. It is a *light* phenomenon, so it has to be computed in linear scene
//     light. The graded image cannot carry it: a 2x specular and a 100x
//     specular both land near 1.0 once the display transform has been applied,
//     so the quantity that drives halation is already gone. These kernels read
//     the ungraded Apple Log 2 frame and decode it.
//  2. The three emulsion layers do not respond equally. Red is re-exposed by
//     the least scattered light, then green, then blue, which is why a halo
//     reads red at low intensity, warm red as it grows, and white once it is
//     bright enough to reach all three. That falls out of per-layer knees and
//     per-layer diffusion radii — not from a colour tint applied afterwards.
//
// Superwhite reference: the Apple Log 2 white paper maps 100% scene reflection
// to decoded linear 1.0, and the recorded 10-bit range reaches about 12x that.
// So `linear - knee` is excess above diffuse white, in multiples of white.

/// Apple Log / Apple Log 2 transfer function, decoded. Constants are Apple's,
/// via OpenColorIO v2.6.0 `AppleCameras.cpp` (BSD-3-Clause), which this repo
/// already vendors for LUT generation. Log 2 shares the curve with Log 1; only
/// the primaries differ.
constant float AL_R0 = -0.05641088f;
constant float AL_RT = 0.01f;
constant float AL_C = 47.28711236f;
constant float AL_BETA = 0.00964052f;
constant float AL_GAMMA = 0.08550479f;
constant float AL_DELTA = 0.69336945f;
constant float AL_PT = AL_C * (AL_RT - AL_R0) * (AL_RT - AL_R0);

static inline float apple_log_decode(float code) {
    if (code >= AL_PT) {
        return pow(2.0f, (code - AL_DELTA) / AL_GAMMA) - AL_BETA;
    }
    if (code >= 0.0f) {
        return sqrt(code / AL_C) + AL_R0;
    }
    return AL_R0;
}

/// Per-layer superwhite energy from the ungraded frame, at half resolution.
///
/// The channels stay separate because they diffuse to different radii and
/// because the ratio between them carries the colour ramp — a single luma value
/// cannot express "red has responded but blue has not".
kernel void spatial_halation_mask(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> mask   [[texture(1)]],
    constant float& redKnee                [[buffer(0)]],
    constant float& greenKnee              [[buffer(1)]],
    constant float& blueKnee               [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) {
        return;
    }

    // 2x2 box average of the full-res source into this half-res texel, averaged
    // in the ENCODED domain: the decode is per-texel, and averaging decoded
    // linear values across a 2x2 would over-weight a single specular.
    float3 sum = float3(0.0f);
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            uint2 src = gid * 2 + uint2(dx, dy);
            if (src.x < input.get_width() && src.y < input.get_height()) {
                sum += input.read(src).rgb;
            }
        }
    }
    float3 encoded = sum * 0.25f;

    float3 linear = float3(apple_log_decode(encoded.r),
                           apple_log_decode(encoded.g),
                           apple_log_decode(encoded.b));

    // Per-layer response. `max(0, linear - knee)` is continuous and grows with
    // intensity, so a brighter source bleeds further and reaches more layers.
    float3 energy = max(float3(0.0f),
                        linear - float3(redKnee, greenKnee, blueKnee));

    mask.write(float4(energy, 1.0f), gid);
}

/// Add the three diffused layers back over the graded image.
///
/// No colour tint is applied. The colour is the consequence of the per-layer
/// physics: red responds to the least light and scatters furthest, so a faint
/// halo reads red; where green and blue have also responded the sum tends to
/// white. Adding the light over the source's own footprint is also what makes a
/// very bright source read as *larger* rather than merely surrounded, since the
/// accumulated energy there saturates toward white.
kernel void spatial_halation_composite(
    texture2d<float, access::read>  graded   [[texture(0)]],
    texture2d<float, access::sample> red     [[texture(1)]],
    texture2d<float, access::sample> green   [[texture(2)]],
    texture2d<float, access::sample> blue    [[texture(3)]],
    texture2d<float, access::write> output   [[texture(4)]],
    constant float& strength                 [[buffer(0)]],
    constant float& shadowFloor              [[buffer(1)]],
    constant float3& layerScale              [[buffer(2)]],
    constant float& referenceSuperwhite      [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float4 base = graded.read(gid);

    // `gid` is in graded/output space, so normalize by the OUTPUT size. The masks
    // are half resolution; normalizing by their own size would double the
    // sampling coordinate and miss the diffusion entirely.
    float2 size = float2(graded.get_width(), graded.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;

    // Each layer is diffused at its own radius, so each keeps its own reach:
    // red is the widest and therefore the only one still present in the far
    // tail, which is what makes a faint halo read red.
    float3 diffusion = float3(red.sample(spatial_linear_sampler, uv).r,
                              green.sample(spatial_linear_sampler, uv).r,
                              blue.sample(spatial_linear_sampler, uv).r);

    // Normalize by the superwhite level that should reach full contribution, so
    // an 11x excess does not swamp the graded image. `layerScale` weights each
    // layer's contribution: red is the strongest because it is the layer most
    // re-exposed by scattered light.
    float3 contribution = diffusion / max(referenceSuperwhite, 0.0001f) * layerScale;

    // Fade the added light out of the deepest shadows so halation never lifts
    // the black point.
    float luminance = spatial_luma(base.rgb);
    float shadowWeight = smoothstep(0.0f, shadowFloor, luminance);

    float3 result = base.rgb + contribution * strength * shadowWeight;

    output.write(float4(result, base.a), gid);
}
