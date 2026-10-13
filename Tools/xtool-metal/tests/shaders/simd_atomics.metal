#include <metal_stdlib>
using namespace metal;

kernel void simd_ops(device float *out [[buffer(0)]], const device float *in [[buffer(1)]],
                     uint gid [[thread_position_in_grid]], uint lane [[thread_index_in_simdgroup]]) {
    float v = in[gid];
    float s = simd_sum(v);
    float m = simd_max(v);
    float x = simd_shuffle_xor(v, ushort(1));
    float d = simd_shuffle_down(v, ushort(1));
    float b = simd_broadcast(v, ushort(3));
    float p = simd_prefix_exclusive_sum(v);
    out[gid * 6 + 0] = s; out[gid * 6 + 1] = m; out[gid * 6 + 2] = x;
    out[gid * 6 + 3] = lane < 31 ? d : 0.0; out[gid * 6 + 4] = b; out[gid * 6 + 5] = p;
}

kernel void tg_atomics(device uint *out [[buffer(0)]], const device uint *in [[buffer(1)]],
                       uint gid [[thread_position_in_grid]], uint lid [[thread_position_in_threadgroup]],
                       uint group [[threadgroup_position_in_grid]]) {
    threadgroup atomic_uint total;
    threadgroup atomic_uint biggest;
    if (lid == 0) { atomic_store_explicit(&total, 0u, memory_order_relaxed); atomic_store_explicit(&biggest, 0u, memory_order_relaxed); }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    atomic_fetch_add_explicit(&total, in[gid], memory_order_relaxed);
    atomic_fetch_max_explicit(&biggest, in[gid], memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid == 0) {
        out[group * 2] = atomic_load_explicit(&total, memory_order_relaxed);
        out[group * 2 + 1] = atomic_load_explicit(&biggest, memory_order_relaxed);
    }
}

kernel void bool_vectors(device float4 *out [[buffer(0)]], const device float4 *in [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    float4 a = in[gid], b = in[gid + 1];
    bool4 m = a < b;
    bool2 n = bool2(m.x, !m.y);
    out[gid] = select(a, b, m) + float4(any(m), all(m), float(n.y), float(m.z && m.w)) + step(0.0, a) + float4(m);
}

kernel void misc_math(device float4 *out [[buffer(0)]], const device float4 *in [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    float4 a = in[gid], b = in[gid + 1], c = in[gid + 2];
    uint4 u = as_type<uint4>(a);
    out[gid * 3 + 0] = min3(a, b, c) + max3(a, b, c) + median3(a, b, c);
    out[gid * 3 + 1] = float4(extract_bits(u.x, 3, 5), insert_bits(u.y, 7u, 4, 3), popcount(u.z), clz(u.w));
    out[gid * 3 + 2] = float4(unpack_unorm4x8_to_float(pack_float_to_unorm4x8(saturate(a)))) + float4(half4(a) * 0.5h);
}
