#include <metal_stdlib>
using namespace metal;

struct CameraPreviewUniforms {
    float2 imageScale;
    uint quarterTurns;
    uint mirrored;
    uint fullRange;
};
struct CameraPreviewVertex { float4 position [[position]]; float2 uv; };

vertex CameraPreviewVertex cameraPreviewVertex(uint id [[vertex_id]],
                                               constant CameraPreviewUniforms &u [[buffer(0)]]) {
    const float2 points[] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                            float2(1,-1), float2(1,1), float2(-1,1)};
    CameraPreviewVertex out;
    out.position = float4(points[id] * u.imageScale, 0, 1);
    out.uv = float2((points[id].x + 1) * .5, (1 - points[id].y) * .5);
    return out;
}

fragment float4 cameraPreviewFragment(CameraPreviewVertex in [[stage_in]],
                                       constant CameraPreviewUniforms &u [[buffer(0)]],
                                       texture2d<float> luma [[texture(0)]],
                                       texture2d<float> chroma [[texture(1)]],
                                       texture3d<float> lut [[texture(2)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    if (u.mirrored) uv.x = 1 - uv.x;
    switch (u.quarterTurns) {
        case 1: uv = float2(uv.y, 1-uv.x); break;
        case 2: uv = 1-uv; break;
        case 3: uv = float2(1-uv.y, uv.x); break;
        default: break;
    }
    // SDK: x420/x422/xf20/xf22 store 10 bits in the MSBs of 16 bits.
    // Unorm hardware sampling divides by 65535, not 1023 or 65536.
    float yCode = luma.sample(linearSampler, uv).r * (65535.0 / 64.0);
    float2 cCode = chroma.sample(linearSampler, uv).rg * (65535.0 / 64.0);
    float y = u.fullRange ? yCode / 1023.0 : (yCode - 64.0) / 876.0;
    float2 c = (cCode - 512.0) / (u.fullRange ? 1023.0 : 896.0);
    // YCbCr matrix only: these RGB values are still Apple Log 2 encoded.
    float3 logRGB = float3(y + 1.4746*c.y, y - .164553*c.x - .571353*c.y, y + 1.8814*c.x);
    float3 size = float3(lut.get_width(), lut.get_height(), lut.get_depth());
    float3 coordinates = (clamp(logRGB, 0.0, 1.0) * (size - 1.0) + .5) / size;
    // Neutral LUT output is Rec.709 encoded. BGRA8Unorm + tagged display layer,
    // deliberately NOT an sRGB render target and NOT an HLG/gamma conversion.
    return float4(lut.sample(linearSampler, coordinates).rgb, 1);
}

// MARK: - Stock-selector plate preview
//
// The selector ships Apple Log 2 encoded plates and applies the selected stock's LUT on the
// GPU, so a user-supplied LUT, a grade tweak or a gauge change needs no new asset. The LUT
// lookup is deliberately identical to cameraPreviewFragment above (red-fastest trilinear,
// clamp-to-edge) so a plate and a live frame grade the same way.
//
// The preview stands in for a full-size render of the same stock, so it runs the same chain
// in the same order, as a render-on-demand multipass:
//
//   plate (Apple Log 2) -> plate_prepare (white balance in linear light, re-encoded)
//                       -> SpatialEffectsStage halation (the production kernels)
//                       -> stock LUT
//                       -> grain sized in the REFERENCE frame's pixels
//
// White balance precedes halation because the camera locks white balance in hardware before
// the renderer ever sees a frame: the halo must scatter the light the lock actually produced.
// Halation is the real `spatial.metal` stage, not a second, tinted halo written for the card.

struct PlatePreviewVertex { float4 position [[position]]; float2 uv; };

vertex PlatePreviewVertex platePreviewVertex(uint id [[vertex_id]]) {
    const float2 points[] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                            float2(1,-1), float2(1,1), float2(-1,1)};
    PlatePreviewVertex out;
    out.position = float4(points[id], 0, 1);
    out.uv = float2((points[id].x + 1) * .5, (1 - points[id].y) * .5);
    return out;
}

// Apple Log 2 constants, shared with Resources/Shaders/spatial.metal.
constant float PLATE_AL0_R0 = -0.05641088f;
constant float PLATE_AL0_RT = 0.01f;
constant float PLATE_AL0_C = 47.28711236f;
constant float PLATE_AL0_BETA = 0.00964052f;
constant float PLATE_AL0_GAMMA = 0.08550479f;
constant float PLATE_AL0_DELTA = 0.69336945f;
/// The toe is a square root of the code, so the two segments meet at the linear value
/// `R_t`, which is the code `c * (R_t - R_0)^2` -- NOT `(R_t - R_0) / c`. Using the linear
/// join put every plate code below ~0.209 through the log segment, then re-encoded it near
/// zero, crushing the shadows and exaggerating whichever channel the gain favoured.
constant float PLATE_AL0_PT = PLATE_AL0_C * (PLATE_AL0_RT - PLATE_AL0_R0) * (PLATE_AL0_RT - PLATE_AL0_R0);

static inline float plate_log2_decode(float code) {
    if (code >= PLATE_AL0_PT) {
        return exp2((code - PLATE_AL0_DELTA) / PLATE_AL0_GAMMA) - PLATE_AL0_BETA;
    }
    if (code >= 0.0f) {
        return sqrt(code / PLATE_AL0_C) + PLATE_AL0_R0;
    }
    return PLATE_AL0_R0;
}

static inline float plate_log2_encode(float linear) {
    if (linear <= PLATE_AL0_R0) {
        return 0.0f;
    }
    return linear < PLATE_AL0_RT
        ? PLATE_AL0_C * (linear - PLATE_AL0_R0) * (linear - PLATE_AL0_R0)
        : PLATE_AL0_DELTA + PLATE_AL0_GAMMA * log2(max(linear, 0.0f) + PLATE_AL0_BETA);
}

/// White-balance preparation uniforms: the identity of the selected stock's lock.
struct PlatePrepareUniforms {
    /// Bradford chromatic adaptation in linear Apple Wide Gamut: it maps the white the
    /// camera locks to (source) onto the scene's illuminant white (destination).
    float3x3 whiteBalance;
};

/// First pass: decode the plate to linear light, apply the stock's white-balance lock, and
/// re-encode to Apple Log 2. Runs at plate resolution, 1:1, so no filtering is involved.
///
/// This is the preview's counterpart to the camera locking white balance in hardware before
/// the renderer sees a frame. Everything downstream -- halation, then the LUT -- therefore
/// operates on the locked light, exactly as the offline render does.
kernel void plate_prepare(texture2d<float, access::read>  plate  [[texture(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          constant PlatePrepareUniforms &u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    float3 code = plate.read(gid).rgb;
    float3 linear = float3(plate_log2_decode(code.r),
                           plate_log2_decode(code.g),
                           plate_log2_decode(code.b));
    linear = u.whiteBalance * linear;
    output.write(float4(plate_log2_encode(linear.r),
                        plate_log2_encode(linear.g),
                        plate_log2_encode(linear.b), 1.0f), gid);
}

/// Final-pass controls: the aspect fit, the drawable size, and the print gauge's grain.
struct PlatePreviewUniforms {
    float2 uvScale;           // aspect-fill: crop rather than stretch the plate
    float2 drawableSize;      // render target size in pixels
    float footprint;          // realised grain cell size in REFERENCE pixels
    float amplitude;          // grain presence: the renderer's own base amount x gauge
    float offset;             // fixed grain phase: the preview is a still
    float referenceLongEdge;  // reference frame's long edge in pixels (3840 for the 4K render)
    float zoom;               // 1 = the whole frame; >1 = a magnified centre crop
};

/// Final pass: grade the prepared, halation-bearing Apple Log 2 frame through the stock LUT,
/// then add gauge grain.
///
/// `prepared` already carries the stock's white balance and the production halation stage's
/// output, so this pass is exactly the offline order -- LUT, then grain.
///
/// Grain is sampled in the REFERENCE frame's pixel space, so a cell keeps the same size
/// relative to the picture at any drawable resolution. The previous implementation divided
/// normalised uv by the footprint, which magnified the grain by the ratio between the
/// drawable and the volume's own 128-texel repeat (3840 / 128 = 30x at 4K).
///
/// `zoom` magnifies a centre crop for the optional detail view. It scales BOTH the sampled
/// region and the grain's reference space, so the magnified crop carries the grain and the
/// halation at the same relative size as the full frame rather than magnifying the photo
/// alone. At `zoom == 1` the pass is byte-for-byte the previous one apart from the grain
/// amount and its luma latitude.
fragment float4 platePreviewFragment(PlatePreviewVertex in [[stage_in]],
                                     constant PlatePreviewUniforms &u [[buffer(0)]],
                                     texture2d<float> prepared [[texture(0)]],
                                     texture3d<float> lut [[texture(1)]],
                                     texture3d<float> grainVolume [[texture(2)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    constexpr sampler grainSampler(coord::normalized, filter::linear, address::repeat);
    float zoom = max(u.zoom, 1.0f);
    // Aspect-fill: crop the plate to the card instead of squeezing it into it. A zoom is the
    // same move with a smaller window, so the two scale the centred offset together.
    float2 uv = clamp((in.uv - 0.5f) * u.uvScale / zoom + 0.5f, 0.0f, 1.0f);
    float3 balanced = prepared.sample(linearSampler, uv).rgb;
    float3 size = float3(lut.get_width(), lut.get_height(), lut.get_depth());
    float3 coordinates = (clamp(balanced, 0.0f, 1.0f) * (size - 1.0f) + .5f) / size;
    float3 graded = lut.sample(linearSampler, coordinates).rgb;
    if (u.amplitude > 0.0f && u.footprint > 0.0f) {
        // Reference pixels per drawable pixel. One 128^3 volume texel is one grain cell, so a
        // cell spans `footprint` reference pixels -- the same quantity pass2_grain samples as
        // gid / (128 * footprint) in the full-size render. Magnifying by `zoom` shrinks the
        // reference space by the same factor, so a cell covers `zoom` times as many drawable
        // pixels: the grain is magnified with the crop, not left behind at card scale.
        float drawableLong = max(u.drawableSize.x, u.drawableSize.y);
        float baseScale = u.referenceLongEdge / max(drawableLong, 1.0f);
        float referenceScale = baseScale / zoom;
        float2 referencePixel = ((in.position.xy - 0.5f * u.drawableSize) / zoom
                                 + 0.5f * u.drawableSize) * baseScale;
        float2 address = referencePixel / (128.0f * u.footprint);
        float3 position = float3(address.x, address.y, 0.0f) + float3(u.offset);
        float noise = grainVolume.sample(grainSampler, position).r * 2.0f - 1.0f;
        // A cell smaller than one drawable pixel cannot be resolved. Averaging the
        // independent cells that fall inside one output pixel reduces the noise RMS by the
        // square root of their count, which is exactly the cell's size in drawable pixels.
        // Fade to that value so subpixel grain reads as fine texture instead of aliasing.
        float cellDrawable = u.footprint / max(referenceScale, 1e-6f);
        float damping = saturate(cellDrawable);
        // `pass2_grain` modulates its amount by the graded luma's latitude: grain fades out of
        // the deepest shadows so it never lifts the black point, and out of the brightest
        // highlights so it never crusts a specular. The preview applies the same window, so
        // the card's grain is the renderer's grain rather than a flat overlay.
        float luminance = dot(graded, float3(0.2126f, 0.7152f, 0.0722f));
        float latitude = smoothstep(0.015f, 0.13f, luminance)
            * (1.0f - smoothstep(0.78f, 0.98f, luminance));
        graded = clamp(graded + noise * u.amplitude * damping * latitude, 0.0f, 1.0f);
    }
    return float4(graded, 1);
}
