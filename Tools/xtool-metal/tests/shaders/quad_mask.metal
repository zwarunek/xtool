#include <metal_stdlib>
using namespace metal;

struct QuadVertex { float2 position; float2 uv; };
struct Affine { float a, b, c, d, tx, ty; };
struct Rounding { float4 radii; float4 inset; };

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut quad_vertex(uint vid [[vertex_id]], constant QuadVertex *verts [[buffer(0)]],
                           constant uint2 *viewport [[buffer(1)]], constant Affine *xf [[buffer(2)]]) {
    float2 p = verts[vid].position;
    Affine t = *xf;
    float2 q = float2(p.x * t.a + p.y * t.c + t.tx, p.x * t.b + p.y * t.d + t.ty);
    QuadOut out;
    out.position = float4(q / (float2(*viewport) / 2.0), 0.0, 1.0);
    out.uv = verts[vid].uv;
    return out;
}

fragment float4 quad_fragment(QuadOut in [[stage_in]], texture2d<half> color [[texture(0)]],
                              texture2d<half> mask [[texture(1)]], constant Rounding *round [[buffer(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 c = color.sample(s, in.uv);
    if (!is_null_texture(mask)) {
        return float4(float3(c.rgb), float(mask.sample(s, in.uv).a * c.a));
    }
    if (round) {
        float2 size = float2(color.get_width(), color.get_height());
        float2 px = in.uv * size;
        float r = round->radii.x;
        float2 corner = float2(r + round->inset.y, r + round->inset.x);
        if (px.x < round->inset.y || px.y < round->inset.x) {
            discard_fragment();
        } else if (px.x < corner.x && px.y < corner.y && distance(px, corner) > r) {
            discard_fragment();
        }
    }
    return float4(c);
}
