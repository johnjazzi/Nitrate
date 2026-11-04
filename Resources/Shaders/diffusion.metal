#include <metal_stdlib>
using namespace metal;

/// Lens diffusion ("mist") diffusion node.
///
/// A diffusion filter scatters a fraction of the light on its way through the
/// glass, so the frame reads softer, with haloes around highlights. That is a
/// LIGHT phenomenon: it is applied to the scene-linear frame before the stock
/// LUT (see `spatial_halation_apply`), exactly like halation, so the scattered
/// light is tone-mapped by the same curve as the light that produced it.
///
/// The blur is the interesting part, because the presets reach far. A direct
/// separable Gaussian with sigma at radius 35 (17.5 texels at the working
/// resolution) needs ~35 taps per axis per pass, and sigma grows linearly with
/// resolution. Instead the blur is built as a MULTI-SCALE LADDER (see
/// `DiffusionPlan`): every level is blurred with the SAME small kernel, and the
/// reach comes from the pyramid, so the tap count is a constant bounded by
/// `DiffusionPlan.maxTaps` no matter how wide the filter is.
///
/// The ladder is only an approximation of ONE smooth spread, and it stops being
/// one when a level cannot afford a real kernel: below about a texel the
/// separable pass is a nearest filter, so the level hands its texel grid back,
/// bilinear upsampling turns each texel into a flat plateau, and the summed
/// result is a hard-edged disc around every highlight instead of a halo.
/// `DiffusionPlan` bounds the depth for that reason — these kernels assume every
/// level they run on is genuinely blurred.
///
/// The three kernels here are the whole cost:
///   `diffusion_downsample` - 3x3 tent, one octave down (clamped edges),
///   `diffusion_blur`       - one separable pass, at most `maxTaps` taps,
///   and the combo + blend, which happens inside `spatial_halation_apply` so
///   the frame is decoded and re-encoded exactly once per pass.

constexpr sampler diffusion_linear_sampler(
    coord::normalized,
    filter::linear,
    address::clamp_to_edge
);

/// One octave down, with a 3x3 tent on the DESTINATION grid.
///
/// Tent rather than a bare 2x2 box: a box halves high-contrast detail into a
/// hard step, which the wide levels then spread into visible blocks. The
/// separable [1 2 1] weights, applied at destination texel spacing through the
/// bilinear sampler, keep the downsample band-limited. Edges clamp, so a
/// uniform field stays uniform instead of darkening into a vignette.
kernel void diffusion_downsample(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float2 size = float2(output.get_width(), output.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;
    float2 texel = 1.0f / size;

    // Separable tent weights: centre 4/16, edges 2/16, corners 1/16.
    const float weight[3] = { 0.25f, 0.5f, 0.25f };
    float4 sum = float4(0.0f);
    for (int y = 0; y < 3; ++y) {
        for (int x = 0; x < 3; ++x) {
            float2 offset = float2(float(x - 1), float(y - 1)) * texel;
            sum += source.sample(diffusion_linear_sampler, uv + offset) * (weight[x] * weight[y]);
        }
    }
    output.write(sum, gid);
}

/// One separable axis of the per-level Gaussian.
///
/// One kernel serves both axes: `direction` is (1,0) or (0,1). The weights
/// arrive precomputed and normalized from `DiffusionPlan`, because they are the
/// same for every level (the level ladder, not the kernel, provides the reach).
///
/// Taps are clamped to the texture edge rather than skipped, so the weights
/// always sum to exactly one: a uniform highlight keeps its value at the frame
/// border instead of falling off. `access::read` (not sampling) keeps the tap
/// count exact; a linear filter would silently fetch between texels.
kernel void diffusion_blur(
    texture2d<float, access::read>  source [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float* weights   [[buffer(0)]],
    constant uint&  taps      [[buffer(1)]],
    constant int2&  direction [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    int2 size = int2(int(source.get_width()), int(source.get_height()));
    int middle = int(taps) / 2;

    float4 sum = float4(0.0f);
    for (uint i = 0; i < taps; ++i) {
        int2 coordinate = clamp(int2(gid) + direction * (int(i) - middle),
                                int2(0), size - 1);
        sum += source.read(uint2(coordinate)) * weights[i];
    }
    output.write(sum, gid);
}
