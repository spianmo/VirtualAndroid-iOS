#include <metal_stdlib>
using namespace metal;

struct VAVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-viewport quad as a 4-vertex triangle strip (BL, BR, TL, TR); the
// per-corner texture coordinates encode the rotation.
vertex VAVertexOut va_display_vertex(uint vid [[vertex_id]],
                                     constant float2 *uvs [[buffer(0)]])
{
    const float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VAVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

fragment float4 va_display_fragment(VAVertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    sampler s [[sampler(0)]])
{
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}
