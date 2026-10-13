#include <metal_stdlib>
using namespace metal;

kernel void float_math(device float4 *out [[buffer(0)]], const device float4 *in [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    float4 x = in[gid];
    float4 y = in[gid + 1] + 0.5;
    uint o = gid * 8;
    out[o + 0] = sin(x) + cos(y) + tan(x * 0.3);
    out[o + 1] = exp(x * 0.5) + log(abs(y) + 1.0) + exp2(x) + log2(abs(x) + 2.0);
    out[o + 2] = sqrt(abs(x)) + rsqrt(abs(y) + 1.0) + pow(abs(x) + 0.1, y);
    out[o + 3] = floor(x * 3.0) + ceil(y) + round(x * 2.0) + trunc(y * 1.5) + fract(x * 7.3);
    out[o + 4] = clamp(x, -0.5, 0.5) + mix(x, y, 0.25) + step(0.2, x) + smoothstep(-1.0, 1.0, y);
    out[o + 5] = float4(dot(x, y), length(x), distance(x, y), length(normalize(y)));
    out[o + 6] = atan2(y, x) + asin(clamp(x, -1.0, 1.0)) + acos(clamp(y * 0.3, -1.0, 1.0)) + sinh(x * 0.2) + tanh(y);
    out[o + 7] = fmod(x * 10.0, y + 2.0) + min(x, y) + max(x, y) + sign(x) + float4(cross(x.xyz, y.xyz), 0.0);
}

kernel void half_math(device half4 *out [[buffer(0)]], const device half4 *in [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    half4 x = in[gid];
    half4 y = in[gid + 1] + 0.5h;
    out[gid * 3 + 0] = sin(x) + cos(y) + sqrt(abs(x));
    out[gid * 3 + 1] = mix(x, y, half4(0.3h)) + clamp(x, -0.5h, 0.5h) + fract(y * 2.0h);
    out[gid * 3 + 2] = half4(dot(x, y), length(x), normalize(y).x, max(x.w, y.w));
}
