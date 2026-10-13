#include <metal_stdlib>
using namespace metal;

struct ScaleParams { float scale; float bias; uint count; };

kernel void scale_bias(device float *out [[buffer(0)]], const device float *in [[buffer(1)]],
                       constant ScaleParams &p [[buffer(2)]], uint gid [[thread_position_in_grid]]) {
    if (gid < p.count) out[gid] = fma(in[gid], p.scale, p.bias);
}

kernel void block_sum(device float *out [[buffer(0)]], const device float *in [[buffer(1)]],
                      device atomic_uint *counter [[buffer(2)]],
                      uint gid [[thread_position_in_grid]], uint lid [[thread_position_in_threadgroup]],
                      uint group [[threadgroup_position_in_grid]], uint width [[threads_per_threadgroup]]) {
    threadgroup float partial[64];
    partial[lid] = in[gid];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = width / 2; stride > 0; stride /= 2) {
        if (lid < stride) partial[lid] += partial[lid + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) {
        out[group] = partial[0];
        atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    }
}

kernel void int_ops(device int4 *out [[buffer(0)]], const device int4 *in [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    int4 v = in[gid];
    int4 w = in[gid + 1];
    out[gid * 4 + 0] = clamp(v, int4(-50), int4(50)) + abs(w);
    out[gid * 4 + 1] = max(v, w) - min(v, w) + int4(popcount(v.x), clz(uint(v.y)), ctz(uint(w.z) | 1u), 0);
    out[gid * 4 + 2] = (v << 2) ^ (w >> 1) | (v & w);
    out[gid * 4 + 3] = int4(uint4(v) / max(uint4(abs(w)), uint4(1))) + v % max(abs(w), int4(1));
}
