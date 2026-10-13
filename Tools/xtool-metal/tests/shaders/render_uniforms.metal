#include <metal_stdlib>
using namespace metal;

struct PatternUniforms {
    float4 tint;
    float4 background;
    float2 size;
    float time;
    float scale;
    float sharpness;
    float3 light;
};

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

static float hash21(float2 p) {
    p = fract(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return fract(p.x * p.y);
}

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    FullscreenOut out;
    out.position = float4(corners[vid], 0.0, 1.0);
    out.uv = corners[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 pattern_fragment(FullscreenOut in [[stage_in]], constant PatternUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * u.size / max(u.size.y, 1.0) * u.scale;
    float2 cell = floor(p);
    float2 f = fract(p) - 0.5;
    float h = hash21(cell);
    float wave = 0.5 + 0.5 * sin(u.time * 2.0 + h * 6.2831853 + length(p));
    float ring = smoothstep(0.45, 0.45 - u.sharpness, length(f) + 0.1 * cos(atan2(f.y, f.x) * 5.0 + u.time));
    float3 n = normalize(float3(f * 2.0, 1.0));
    float diffuse = max(dot(n, normalize(u.light)), 0.0);
    float shade = pow(diffuse, 1.5) * 0.7 + 0.3;
    float3 c = mix(u.background.rgb, u.tint.rgb * shade, ring * wave);
    c += 0.05 * fmod(cell.x + cell.y, 2.0);
    return float4(saturate(c), 1.0);
}
