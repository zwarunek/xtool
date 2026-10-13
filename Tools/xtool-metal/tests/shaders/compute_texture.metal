#include <metal_stdlib>
using namespace metal;

kernel void blur_copy(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint w = src.get_width(), h = src.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 acc = float4(0.0);
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            uint2 c = uint2(clamp(int2(gid) + int2(dx, dy), int2(0), int2(w - 1, h - 1)));
            acc += src.read(c);
        }
    }
    dst.write(acc / 9.0, gid);
}

kernel void sample_grid(texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]], device float4 *out [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float2 uv = (float2(gid) + 0.5) / 8.0;
    constexpr sampler rep(address::repeat, filter::nearest);
    out[gid.y * 8 + gid.x] = src.sample(smp, uv * 1.3) + src.sample(rep, uv * 2.7 - 0.2) * 0.5 + src.sample(smp, uv, level(0.0)) * 0.25;
}
