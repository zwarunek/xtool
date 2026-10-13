#include <metal_stdlib>
using namespace metal;

static float3 hue_to_rgb(float h) {
    float3 k = fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
    return saturate(abs(k) - 1.0);
}

[[stitchable]] half4 tile_effect(float2 position, half4 color, float4 bounds, float time, float tiles, float hue) {
    float2 uv = position / bounds.zw;
    float2 cell = floor(uv * tiles);
    float checker = fmod(cell.x + cell.y, 2.0);
    float wave = 0.5 + 0.5 * sin(time + cell.x * 0.7 + cell.y * 1.3);
    float3 rgb = hue_to_rgb(fract(hue / 360.0 + 0.1 * checker)) * (0.4 + 0.6 * wave);
    return half4(half3(rgb), 1.0h) * color.a + half4(color.rgb, 0.0h) * 0.1h;
}
