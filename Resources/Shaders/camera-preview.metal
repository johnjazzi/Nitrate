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
// The selector ships Apple Log 2 encoded plates and applies the selected stock LUT on the
// GPU, so a user-supplied LUT, a grade tweak or a gauge change needs no new asset. The LUT
// lookup is deliberately identical to cameraPreviewFragment above (red-fastest trilinear,
// clamp-to-edge) so a plate and a live frame grade the same way.

struct PlatePreviewVertex { float4 position [[position]]; float2 uv; };

vertex PlatePreviewVertex platePreviewVertex(uint id [[vertex_id]]) {
    const float2 points[] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                            float2(1,-1), float2(1,1), float2(-1,1)};
    PlatePreviewVertex out;
    out.position = float4(points[id], 0, 1);
    out.uv = float2((points[id].x + 1) * .5, (1 - points[id].y) * .5);
    return out;
}

fragment float4 platePreviewFragment(PlatePreviewVertex in [[stage_in]],
                                     texture2d<float> plate [[texture(0)]],
                                     texture3d<float> lut [[texture(1)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    // The plate is already Apple Log 2 encoded, so it feeds the cube directly.
    float3 logRGB = plate.sample(linearSampler, in.uv).rgb;
    float3 size = float3(lut.get_width(), lut.get_height(), lut.get_depth());
    float3 coordinates = (clamp(logRGB, 0.0, 1.0) * (size - 1.0) + .5) / size;
    return float4(lut.sample(linearSampler, coordinates).rgb, 1);
}
