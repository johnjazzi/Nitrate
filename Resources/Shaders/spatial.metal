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

/// Rec.709 luma of an Apple Log 2 code value triple.
static inline float spatial_luma(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

/// Extract a highlight mask from the source image.
///
/// Reads the full-resolution source (Apple Log 2 code values) but writes a
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

/// Separable Gaussian blur, horizontal pass.
///
/// Nine taps with linear-filtering offsets, so one sample stands in for two
/// texels. `radius` is in texels; larger radii also feed the wider glow.
kernel void spatial_blur_h(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant float& radius                  [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float2 size = float2(input.get_width(), input.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;

    const float weights[5] = { 0.2270270270f, 0.1945945946f, 0.1216216216f,
                               0.0540540541f, 0.0162162162f };
    // Offsets paired for linear sampling: 1.3846153846 and 3.2307692308 texels.
    const float offsets[5] = { 0.0f, 1.3846153846f, 3.2307692308f,
                               5.0769230769f, 6.9230769231f };

    float4 sum = input.sample(spatial_linear_sampler, uv) * weights[0];
    for (int i = 1; i < 5; ++i) {
        float offset = offsets[i] * radius / size.x;
        sum += input.sample(spatial_linear_sampler, uv + float2(offset, 0.0f)) * weights[i];
        sum += input.sample(spatial_linear_sampler, uv - float2(offset, 0.0f)) * weights[i];
    }

    output.write(sum, gid);
}

/// Separable Gaussian blur, vertical pass.
kernel void spatial_blur_v(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant float& radius                  [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float2 size = float2(input.get_width(), input.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;

    const float weights[5] = { 0.2270270270f, 0.1945945946f, 0.1216216216f,
                               0.0540540541f, 0.0162162162f };
    const float offsets[5] = { 0.0f, 1.3846153846f, 3.2307692308f,
                               5.0769230769f, 6.9230769231f };

    float4 sum = input.sample(spatial_linear_sampler, uv) * weights[0];
    for (int i = 1; i < 5; ++i) {
        float offset = offsets[i] * radius / size.y;
        sum += input.sample(spatial_linear_sampler, uv + float2(0.0f, offset)) * weights[i];
        sum += input.sample(spatial_linear_sampler, uv - float2(0.0f, offset)) * weights[i];
    }

    output.write(sum, gid);
}

/// Composite a blurred mask back over the graded image.
///
/// `strength` carries the stock's halation or glow value and `tint` its colour
/// cast, so this is a plain additive screen-in of tinted light with the image's
/// luminance modulating the effect so shadows stay clean.
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

    // Fade the added light out of the deepest shadows so halation and glow
    // never lift the black point (the old constant glow term did exactly that).
    float luminance = spatial_luma(base.rgb);
    float shadowWeight = smoothstep(0.0f, shadowFloor, luminance);

    float3 result = base.rgb + tint * spread * strength * shadowWeight;

    output.write(float4(result, base.a), gid);
}
