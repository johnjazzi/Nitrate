#include <metal_stdlib>
#include "hlg-input.h"
using namespace metal;

// Native ten-bit HLG YCbCr -> existing LUT input. No display tone mapping.
kernel void hlg_prepare(texture2d<float, access::read> yPlane [[texture(0)]],
                        texture2d<float, access::sample> uvPlane [[texture(1)]],
                        texture2d<float, access::write> output [[texture(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler chromaSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float y = (yPlane.read(gid).r * (65535.0f / 64.0f) - 64.0f) / 876.0f;
    float2 uv = (float2(gid) + .5f) / float2(output.get_width(), output.get_height());
    float2 c = (uvPlane.sample(chromaSampler, uv).rg * (65535.0f / 64.0f) - 512.0f) / 896.0f;
    float3 rgb = float3(y + 1.4746f*c.y, y - .164553f*c.x - .571353f*c.y, y + 1.8814f*c.x);
    output.write(float4(hlg_to_lut_input(rgb), 1), gid);
}

constexpr sampler spatial_linear_sampler(
    coord::normalized,
    filter::linear,
    address::clamp_to_edge
);

/// Spatial halation + glow (epic story 1.4).
///
/// Two independent effects live here and must stay independent.
///
/// HALATION is a scene-light phenomenon and is applied BEFORE the stock LUT.
/// `spatial_halation_mask` reads the ungraded Apple Log 2 frame, decodes it to
/// linear scene light, and takes each emulsion layer's excess above its knee.
/// `spatial_halation_apply` then decodes the source again, adds the diffused
/// per-layer energy in LINEAR light, and re-encodes the result to Apple Log 2.
/// The stock LUT and output contrast are applied to that re-encoded frame
/// afterwards, so the scattered light is tone-mapped by the same curve as the
/// light that produced it: the halo rolls off with the highlight instead of
/// clipping into a detached fringe. Nothing here reads or writes the graded
/// image, and there is no shadow gate — the light that scatters is the light
/// that is added.
///
/// GLOW is an optical-filter bloom with no physical model. It keeps the
/// graded-luminance highlight mask (`spatial_mask`) and the tinted additive
/// composite (`spatial_composite`) it always had, and is applied AFTER the LUT.
/// Its look is deliberately unchanged by the halation work.
///
/// Masks and diffusions are built and blurred at HALF resolution. Halation and
/// glow are low-frequency by nature, so half-res blurring is visually
/// equivalent while cutting the scratch-texture cost (and bandwidth) by roughly
/// 4x at 4K.

/// Rec.709 luma of the post-LUT graded image.
static inline float spatial_luma(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

/// Extract a highlight mask from the GRADED image for the glow bloom.
///
/// Reads the full-resolution graded source but writes a half-resolution,
/// UNTINTED mask (the highlight weight in all three channels). The tint is
/// applied at composite time, so a stock change never needs a re-blur.
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

/// Composite a blurred GLOW mask back over the graded image.
///
/// A plain additive, tinted bloom. `strength` carries the stock's glow value
/// and `tint` its colour cast; the image's own luminance fades the effect out of
/// the deepest shadows so glow never lifts the black point. Glow is a bloom, not
/// a ring: it is added as a filled spread with no hole punched in the centre.
/// Halation does not use this kernel — see `spatial_halation_apply`.
kernel void spatial_composite(
    texture2d<float, access::read>  graded   [[texture(0)]],
    texture2d<float, access::sample> mask     [[texture(1)]],
    texture2d<float, access::write> output    [[texture(2)]],
    constant float& strength                  [[buffer(0)]],
    constant float& shadowFloor               [[buffer(1)]],
    constant float3& tint                     [[buffer(2)]],
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

    // Fade the added light out of the deepest shadows so glow never lifts the
    // black point (the old constant glow term did exactly that).
    float luminance = spatial_luma(base.rgb);
    float shadowWeight = smoothstep(0.0f, shadowFloor, luminance);

    float3 result = base.rgb + tint * spread * strength * shadowWeight;

    output.write(float4(result, base.a), gid);
}

// ===========================================================================
// Physical halation (pre-LUT, scene-linear)
// ===========================================================================
//
// Halation is light crossing the emulsion, reflecting off the film base or the
// anti-halation backing, and re-exposing the surrounding emulsion. Three things
// follow, and every implementation before this one got at least one wrong:
//
//  1. It is a *light* phenomenon, so it is computed in linear scene light. A 2x
//     specular and a 100x specular both land near 1.0 once the display transform
//     has been applied, so the quantity that drives halation is already gone
//     after the LUT. These kernels read the ungraded Apple Log 2 frame and
//     decode it, add the scattered light in linear, and re-encode.
//  2. The three emulsion layers do not respond equally. Red is re-exposed by the
//     least scattered light, then green, then blue, which is why a halo reads
//     red at low intensity, warm red as it grows, and white once it is bright
//     enough to reach all three. That falls out of per-layer knees and
//     per-layer diffusion radii — not from a colour tint applied afterwards.
//  3. The reflected light lands across the source's own footprint too. It is
//     added, never subtracted, so a very bright source reads as *larger* rather
//     than being hollowed into a ring.
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

/// Inverse of `apple_log_decode`: linear scene light back to Apple Log 2 code.
/// Applied to the halation result so the frame re-enters the pipeline in the
/// same encoding the stock LUT expects.
static inline float apple_log_encode(float linear) {
    if (linear >= AL_RT) {
        return AL_DELTA + AL_GAMMA * log2(linear + AL_BETA);
    }
    return AL_C * (linear - AL_R0) * (linear - AL_R0);
}

/// Decode the (scale x scale) source block under one mask texel into linear
/// scene light and average it there.
///
/// Each sample is decoded BEFORE the average. Apple Log is a nonlinear
/// encoding, so averaging the code values and decoding once (the previous
/// behaviour) collapses a subpixel specular into the mean of its surround
/// instead of preserving its energy — a 9x pixel next to three 18% pixels would
/// fall below red's knee entirely. Only samples that actually fall inside the
/// source are counted, so a mask texel on an odd-sized frame averages the
/// pixels that exist rather than always dividing by four.
///
/// Shared by both prepare entry points below so the halation mask, the
/// diffusion scene, and any future consumer of scene light can never disagree
/// about the decode.
static inline float3 spatial_linear_block(
    texture2d<float, access::read> input,
    uint2 gid,
    uint scale,
    thread uint& valid
) {
    float3 sum = float3(0.0f);
    valid = 0;
    for (uint dy = 0; dy < scale; ++dy) {
        for (uint dx = 0; dx < scale; ++dx) {
            uint2 src = gid * scale + uint2(dx, dy);
            if (src.x < input.get_width() && src.y < input.get_height()) {
                float3 encoded = input.read(src).rgb;
                sum += float3(apple_log_decode(encoded.r),
                              apple_log_decode(encoded.g),
                              apple_log_decode(encoded.b));
                valid += 1;
            }
        }
    }
    return sum / max(float(valid), 1.0f);
}

/// Per-layer superwhite energy from the ungraded frame, at half resolution.
///
/// The channels stay separate because they diffuse to different radii and
/// because the ratio between them carries the colour ramp — a single luma value
/// cannot express "red has responded but blue has not".
///
/// `scale` is 1 when the mask is full resolution: zero diffusion avoids even
/// the implicit spread introduced by half-resolution downsampling and linear
/// upsampling.
static inline uint spatial_mask_scale(
    texture2d<float, access::write> mask,
    texture2d<float, access::read> input
) {
    return (mask.get_width() == input.get_width()
            && mask.get_height() == input.get_height()) ? 1u : 2u;
}

/// How far below the ceiling, in stops, the PULL gain rolls off. The gain is
/// applied in full up to `2^holdStops` under the clip and fades to none at the
/// clip itself. Widen it to protect more of the shoulder, narrow it to leave
/// only the last fraction of a stop alone. It is the one taste constant of the
/// curve; every other number here is derived.
constant float kPushPullHoldStops = 1.0f;

/// Pull gain weight at one scene-light value: 1 where the exposure is applied in
/// full, 0 at and above the clip ceiling — so a truly clipped highlight does not
/// move and keeps driving halation at full intensity.
static inline float spatial_hold_weight(float linear, float ceiling) {
    if (ceiling <= 0.0f || linear <= 0.0f) {
        // Below black the direction clamp owns the result; above a missing
        // ceiling there is nothing to hold.
        return 1.0f;
    }
    float below = log2(ceiling / linear) / kPushPullHoldStops; // stops under the clip
    below = clamp(below, 0.0f, 1.0f);
    return below * below * (3.0f - 2.0f * below);              // smoothstep
}

/// Render-time push/pull as a highlight-preserving exposure CURVE, applied to
/// scene light BEFORE the emulsion stages.
///
/// A video take is locked to its shutter, so a bright day is over-exposed at the
/// sensor and the operator pulls the exposure down in the render. Applying that
/// pull AFTER halation meant the emulsion was still measured against the light
/// the sensor saw: the frame came back two stops darker with two stops too much
/// halo. Exposing the scene first puts the pull where a real exposure change
/// would be — in front of the film.
///
/// It is a CURVE, not a flat gain. A flat ±EV multiplies the whole scene, so a
/// pull drags the truly clipped highlights (which carry no scene detail to
/// recover) down out of white and into midtones — and there they pick up the
/// base stock's cast instead of reading as film. Film does the opposite: light
/// past the emulsion's latitude stays fully developed, prints as white, and
/// halates. So the gain fades to none at the source's clip ceiling: midtones and
/// the recoverable shoulder pull down, while a clipped highlight holds at white
/// and keeps its full-intensity halo.
/// Positive stops instead use a monotone rational shoulder below the ceiling,
/// with identity at/above it. Blending a positive gain by the pull weight would
/// overshoot the ceiling and invert gradients as the weight falls to zero.
///
/// Apple Log 2 is signed: codes under the black point carry NEGATIVE scene
/// values, and scaling those toward zero would move them against the requested
/// direction. Clamp so a pull only ever darkens and a push only ever brightens.
static inline float3 spatial_expose(float3 linear, float stops, float ceiling) {
    if (stops == 0.0f) {
        return linear;
    }
    float gain = exp2(stops);
    if (stops > 0.0f) {
        float3 exposed = linear * gain;
        if (isfinite(ceiling) && ceiling > 0.0f) {
            // Monotone, bounded shoulder; at/above the ceiling is identity.
            // Negative light uses flat gain before the signed-black clamp.
            exposed /= 1.0f + (gain - 1.0f) * max(linear, 0.0f) / ceiling;
            exposed = select(exposed, linear, linear >= ceiling);
        }
        return max(exposed, linear);
    }
    float3 weight = float3(spatial_hold_weight(linear.x, ceiling),
                           spatial_hold_weight(linear.y, ceiling),
                           spatial_hold_weight(linear.z, ceiling));
    float3 exposed = linear * (1.0f + (gain - 1.0f) * weight);
    return stops < 0.0f ? min(exposed, linear) : max(exposed, linear);
}

static inline float3 spatial_energy(float3 linear, float3 knees) {
    // Per-layer response. `max(0, linear - knee)` is continuous and grows with
    // intensity, so a brighter source bleeds further and reaches more layers.
    // The knee ordering is explicit and fixed — red (least scattered light,
    // clears first), then green, then blue — and must never be permuted: it is
    // what makes a faint halo read red and a bright one read white.
    return max(float3(0.0f), linear - knees);
}

kernel void spatial_halation_mask(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> mask   [[texture(1)]],
    constant float& redKnee                [[buffer(0)]],
    constant float& greenKnee              [[buffer(1)]],
    constant float& blueKnee               [[buffer(2)]],
    constant float& exposureStops          [[buffer(3)]],
    constant float& exposureCeiling        [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) {
        return;
    }

    uint valid = 0;
    float3 linear = spatial_expose(
        spatial_linear_block(input, gid, spatial_mask_scale(mask, input), valid),
        exposureStops, exposureCeiling);
    float3 energy = spatial_energy(linear, float3(redKnee, greenKnee, blueKnee));

    mask.write(float4(energy, 1.0f), gid);
}

/// The same halation mask, plus the scene-linear frame the diffusion node
/// blurs, from ONE decode.
///
/// Diffusion scatters light in linear scene light, so it needs the decoded
/// frame; halation needs the per-layer excess of that same frame. Decoding
/// twice would double the half-res read traffic for no benefit, so this entry
/// point writes both. It is used only when the diffusion node is enabled — the
/// mask-only kernel above stays the default path so a disabled diffusion node
/// allocates and writes nothing.
kernel void spatial_scene_prepare(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> mask   [[texture(1)]],
    texture2d<float, access::write> linear [[texture(2)]],
    constant float& redKnee                [[buffer(0)]],
    constant float& greenKnee              [[buffer(1)]],
    constant float& blueKnee               [[buffer(2)]],
    constant float& exposureStops          [[buffer(3)]],
    constant float& exposureCeiling        [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) {
        return;
    }

    uint valid = 0;
    float3 scene = spatial_expose(
        spatial_linear_block(input, gid, spatial_mask_scale(mask, input), valid),
        exposureStops, exposureCeiling);
    float3 energy = spatial_energy(scene, float3(redKnee, greenKnee, blueKnee));

    mask.write(float4(energy, 1.0f), gid);
    linear.write(float4(scene, 1.0f), gid);
}

/// Add the three diffused layers to the scene-linear source, then re-encode —
/// and, in the same pass, apply the lens diffusion node.
///
/// The source is decoded per channel once, the diffusion blend and then the
/// diffused per-layer halation energy are applied in linear light, and the sum
/// is re-encoded to Apple Log 2 exactly once. That re-encoded frame is what the
/// stock LUT and output contrast grade, so both effects share the source's tone
/// curve and neither pays for its own decode/encode round trip.
///
/// ORDER IS PHYSICAL: a diffusion filter sits in front of the lens, so it
/// softens the scene light BEFORE the emulsion scatters it. The halation layers
/// are therefore added to the DIFFUSED scene, not the other way round.
///
/// Halation applies no colour tint: the colour is the consequence of the
/// per-layer physics — red responds to the least light and scatters furthest,
/// so a faint halo reads red, and where green and blue have also responded the
/// sum tends to white. The energy is ADDED over the source's own footprint as
/// well, which is why a very bright source reads as larger rather than hollowed
/// into a ring.
kernel void spatial_halation_apply(
    texture2d<float, access::read>  source [[texture(0)]],
    texture2d<float, access::sample> red   [[texture(1)]],
    texture2d<float, access::sample> green [[texture(2)]],
    texture2d<float, access::sample> blue  [[texture(3)]],
    texture2d<float, access::write> output [[texture(4)]],
    texture2d<float, access::sample> diffusionLevel0 [[texture(5)]],
    texture2d<float, access::sample> diffusionLevel1 [[texture(6)]],
    texture2d<float, access::sample> diffusionLevel2 [[texture(7)]],
    texture2d<float, access::sample> diffusionLevel3 [[texture(8)]],
    constant float& strength               [[buffer(0)]],
    constant float3& layerScale            [[buffer(1)]],
    constant float& referenceSuperwhite    [[buffer(2)]],
    constant float4& diffusionWeights      [[buffer(3)]],
    constant float& diffusionAmount        [[buffer(4)]],
    constant float& exposureStops          [[buffer(5)]],
    constant float& exposureCeiling        [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float4 base = source.read(gid);

    // `gid` is in source/output space, so normalize by the OUTPUT size. The
    // masks are half resolution; normalizing by their own size would double the
    // sampling coordinate and miss the diffusion entirely.
    float2 size = float2(source.get_width(), source.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;

    // Each layer is diffused at its own radius, so each keeps its own reach:
    // red is the widest and therefore the only one still present in the far
    // tail, which is what makes a faint halo read red. Each layer's OWN channel
    // is read — the mask carries a distinct per-layer energy in rgb, so sampling
    // `.r` from all three would feed red's energy into the green and blue layers
    // and let an all-red source masquerade as full RGB.
    float3 diffusion = float3(red.sample(spatial_linear_sampler, uv).r,
                              green.sample(spatial_linear_sampler, uv).g,
                              blue.sample(spatial_linear_sampler, uv).b);

    // Normalize by the superwhite level that should reach full contribution, so
    // an 11x excess does not swamp the graded image. `layerScale` weights each
    // layer's contribution: red is the strongest because it is the layer most
    // re-exposed by scattered light.
    float3 contribution = diffusion / max(referenceSuperwhite, 0.0001f) * layerScale * strength;

    // Decode the source to linear scene light, add the scattered energy there,
    // and re-encode. Adding in the encoded domain instead would apply the log
    // curve twice and detach the halo from the highlight it came from.
    float3 linear = spatial_expose(float3(apple_log_decode(base.r),
                                          apple_log_decode(base.g),
                                          apple_log_decode(base.b)),
                                   exposureStops, exposureCeiling);

    // Lens diffusion: blend the scene light toward the multi-scale blurred
    // version. The levels are the same blur sampled at three (or four) scales;
    // their weights carry the Gaussian's variance, and the sum is normalized
    // on the CPU, so this stays a weighted average and cannot change exposure.
    // Skipped entirely when the node is off, so a disabled node is not a small
    // blur but an exact pass-through.
    if (diffusionAmount > 0.0f) {
        float3 near = diffusionLevel0.sample(spatial_linear_sampler, uv).rgb;
        float3 mid  = diffusionLevel1.sample(spatial_linear_sampler, uv).rgb;
        float3 far  = diffusionLevel2.sample(spatial_linear_sampler, uv).rgb;
        float3 farthest = diffusionLevel3.sample(spatial_linear_sampler, uv).rgb;
        float3 blurred = near * diffusionWeights.x + mid * diffusionWeights.y
                       + far * diffusionWeights.z + farthest * diffusionWeights.w;
        float weightSum = diffusionWeights.x + diffusionWeights.y
                        + diffusionWeights.z + diffusionWeights.w;
        blurred = blurred / max(weightSum, 1e-6f);
        linear = mix(linear, blurred, clamp(diffusionAmount, 0.0f, 1.0f));
    }

    float3 scattered = max(float3(0.0f), linear + contribution);

    output.write(float4(apple_log_encode(scattered.r),
                        apple_log_encode(scattered.g),
                        apple_log_encode(scattered.b),
                        base.a), gid);
}
