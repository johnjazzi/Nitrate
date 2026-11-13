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
    float iso;           // ISO value scaling grain loudness (not size)
    float grainSize;     // effective grain footprint (stock size × gauge size)
    float edgeBoostMultiplier;
    float gaugeAmplitude; // print gauge amplitude multiplier (m00581)
    // Strength of the anti-correlated red/blue dye-cloud component relative to
    // the shared luminance grain. Real emulsion grain is overwhelmingly a
    // density (luminance) fluctuation; the colour layers add only a little
    // decorrelated grain. Video can carry more of it because the eye integrates
    // several frames, a single still viewed at 1:1 cannot.
    float chromaAmount;
    // Reference pixels per raster pixel for the frame this pass writes, from
    // `GrainModel.referenceScale(width:height:)`. The cell is authored in the
    // 4K delivery render's pixels, so a smaller raster (a digitally cropped
    // still, a 4:3 delivery crop) scales the cell by this before sampling.
    // 1 leaves it unchanged.
    float referenceScale;
};

/// Pass 2: 3D noise volume grain with temporal coherence (AD-9).
///
/// Samples coherent fine and clump scales from the shipped volume, with
/// restrained chroma variation and a mild normalized detail prefilter.

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
    float3 source = select(float3(0.0f), color.rgb, isfinite(color.rgb));
    float alpha = isfinite(color.a) ? color.a : 0.0f;

    // A normalized cross prefilter reduces detail below the grain scale.
    // Positive weights preserve constant regions and cannot create halos.
    uint width = input.get_width();
    uint height = input.get_height();
    uint2 left = uint2(gid.x > 0 ? gid.x - 1 : gid.x, gid.y);
    uint2 right = uint2(min(gid.x + 1, width - 1), gid.y);
    uint2 up = uint2(gid.x, gid.y > 0 ? gid.y - 1 : gid.y);
    uint2 down = uint2(gid.x, min(gid.y + 1, height - 1));
    float3 leftColor = input.read(left).rgb;
    float3 rightColor = input.read(right).rgb;
    float3 upColor = input.read(up).rgb;
    float3 downColor = input.read(down).rgb;
    float3 safeLeft = select(float3(0.0f), leftColor, isfinite(leftColor));
    float3 safeRight = select(float3(0.0f), rightColor, isfinite(rightColor));
    float3 safeUp = select(float3(0.0f), upColor, isfinite(upColor));
    float3 safeDown = select(float3(0.0f), downColor, isfinite(downColor));
    float3 softened = source * 0.5f
        + safeLeft * 0.125f
        + safeRight * 0.125f
        + safeUp * 0.125f
        + safeDown * 0.125f;

    float sourceLumaLeft = dot(safeLeft, float3(0.2126f, 0.7152f, 0.0722f));
    float sourceLumaRight = dot(safeRight, float3(0.2126f, 0.7152f, 0.0722f));
    float sourceLumaUp = dot(safeUp, float3(0.2126f, 0.7152f, 0.0722f));
    float sourceLumaDown = dot(safeDown, float3(0.2126f, 0.7152f, 0.0722f));
    float edgeMagnitude = length(float2(sourceLumaRight - sourceLumaLeft, sourceLumaDown - sourceLumaUp));
    float edgeBoost = isfinite(uniforms.edgeBoostMultiplier)
        && uniforms.edgeBoostMultiplier >= 0.0f && uniforms.edgeBoostMultiplier <= 3.0f
        ? uniforms.edgeBoostMultiplier : 0.0f;
    float edgeFactor = 1.0f + saturate(edgeMagnitude * 3.0f) * edgeBoost;

    float grainSize = isfinite(uniforms.grainSize) && uniforms.grainSize > 0.0f
        ? uniforms.grainSize : 1.0f;
    float gaugeAmplitude = isfinite(uniforms.gaugeAmplitude) ? max(uniforms.gaugeAmplitude, 0.0f) : 1.0f;
    // The print gauge owns grain entirely: size (footprint) and presence
    // (gaugeAmplitude). ISO does not scale grain loudness — it is the exposure
    // index only. `uniforms.iso` is retained in the struct for ABI stability.
    float sizeSoftness = smoothstep(0.55f, 1.5f, grainSize) * 0.10f;
    float3 base = mix(source, softened, clamp(sizeSoftness, 0.0f, 0.18f));

    // Frame-level irrational offsets retain spatial continuity while avoiding
    // per-pixel coordinate jumps and the old 128-frame z-slice loop.
    float frame = float(uniforms.frameIndex);
    float phase = frame * 0.754877666f;
    float2 frameOffset = float2(fract(phase * 0.347f), fract(phase * 0.619f));
    // Sample the center of one volume plane per frame. Trilinear Z blending
    // changes the plane's realized RMS as the irrational phase crosses slices,
    // which creates visible global grain pumping. In-plane offsets continue to
    // animate the field, including after the 128-plane index wraps.
    float zSlice = (fmod(frame, 128.0f) + 0.5f) / 128.0f;
    // The print gauge owns size, so footprint must not depend on ISO. Below a
    // footprint of ~1.0 the 128³ volume is undersampled (lag-1 correlation
    // collapses) and finer size yields aliased noise, not finer grain. Floor the
    // effective size off that regime; 75mm's remaining graininess is removed by
    // the amplitude multiplier instead. grainSize is already stock × gauge.
    // `grainSize` is authored in REFERENCE-frame pixels: one 128^3 volume texel
    // is one grain cell, and one cell spans `footprint` pixels of the 4K
    // delivery render every gauge was tuned on. This pass may write a smaller
    // raster -- a digitally cropped still, or a 4:3 delivery crop -- so convert
    // the cell to THIS raster's pixels first. Without that, a cropped still
    // carried grain magnified by exactly the crop factor.
    float referenceScale = isfinite(uniforms.referenceScale) && uniforms.referenceScale > 0.0f
        ? uniforms.referenceScale : 1.0f;
    float footprint = clamp(grainSize, 0.95f, 16.0f) / referenceScale;
    // A cell below one raster pixel cannot be resolved by a point-sampled
    // volume. Scale the excursion by the cell -- the RMS of the independent
    // cells that fall inside one output pixel -- so subpixel grain reads as
    // fine texture instead of aliased noise. Same rule the preview applies to
    // its drawable.
    float cellDamping = saturate(footprint);
    float2 pixelCoord = float2(gid) / (128.0f * max(footprint, 0.1f));
    // A slowly varying vector displacement breaks the 128-texel repeat without
    // introducing pixelwise UV jumps. Its incommensurate scale keeps the field
    // spatially coherent while moving the composite repeat beyond video frames.
    float2 warpCoord = fract(pixelCoord * 0.035f + frameOffset.yx + float2(0.419f, 0.137f));
    float warpX = (grainVol.sample(grain_sampler, float3(warpCoord, zSlice)).r - 0.5f) * 2.0f;
    float warpY = (grainVol.sample(grain_sampler,
        float3(fract(warpCoord * 1.324717957f + float2(0.271f, 0.593f)), zSlice)).r - 0.5f) * 2.0f;
    float2 warp = float2(warpX, warpY) * 0.22f;
    float2 fineCoord = fract(pixelCoord + frameOffset + warp);
    float2 clumpCoord = fract(pixelCoord * 0.381966011f + frameOffset.yx + float2(0.173f, 0.293f));
    float fine = (grainVol.sample(grain_sampler, float3(fineCoord, zSlice)).r - 0.5f) * 2.0f;
    float clump = (grainVol.sample(grain_sampler, float3(clumpCoord, zSlice)).r - 0.5f) * 2.0f;
    float2 chromaCoord = fract(pixelCoord * 1.618033989f + frameOffset.yx + float2(0.317f, 0.113f));
    float chroma = (grainVol.sample(grain_sampler, float3(chromaCoord, zSlice)).r - 0.5f) * 2.0f;
    float shared = fine * 0.74f + clump * 0.26f;
    float chromaAmount = isfinite(uniforms.chromaAmount) && uniforms.chromaAmount >= 0.0f
        ? uniforms.chromaAmount : 0.0f;
    float3 grain = shared + float3(-1.0f, 0.125f, 1.0f) * (chroma * chromaAmount);

    float luminance = dot(base, float3(0.2126f, 0.7152f, 0.0722f));
    // Asymmetric luma gate. The toe holds at zero through the deepest shadow — from
    // black up to luma 0.06 nothing is added at all — and only reaches full strength
    // at 0.24, so grain is not visible in dark areas where a print carries almost no
    // density variation. Because it starts above zero, a true black input still gets
    // an exactly zero excursion and the black point cannot be lifted. The highlight shoulder is a
    // far wider ramp than the old 0.78-0.98 window: it begins at 0.56 so bright tones
    // clean up earlier, yet only reaches ~3.6% at luma 0.95 and zero at pure white, so
    // a specular keeps a faint trace instead of being hard-clipped flat.
    float toe = smoothstep(0.06f, 0.24f, luminance);
    float shoulder = 1.0f - smoothstep(0.56f, 1.0f, luminance);
    float latitude = toe * shoulder;
    float amount = 0.55f * gaugeAmplitude * edgeFactor * cellDamping;
    float3 excursion = grain * (amount * latitude);
    excursion += fine * (0.004f * latitude);

    // Budget the worst possible excursion before applying the symmetric noise.
    // The shipped volume spans [0.385, 0.615], so each centered component is
    // bounded by 0.23; shared, chroma and dither terms are included below.
    // Reserve two delivery-code steps to keep positive values out of 8-bit black.
    float3 headroom = max(float3(0.0f), min(base, 1.0f - base) - (2.0f / 255.0f));
    float maximumExcursion = latitude * 0.23f * (amount * (1.0f + chromaAmount) + 0.004f);
    float3 budgetScale = maximumExcursion > 0.0f
        ? min(float3(1.0f), headroom / maximumExcursion) : float3(1.0f);
    float3 result = clamp(base + excursion * budgetScale, 0.0f, 1.0f);
    output.write(float4(result, alpha), gid);
}
