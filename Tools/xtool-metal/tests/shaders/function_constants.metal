#include <metal_stdlib>
using namespace metal;

constant bool useScale [[function_constant(0)]];
constant float scaleFactor [[function_constant(1)]];
constant int extraPasses [[function_constant(2)]];

kernel void fc_kernel(device float *out [[buffer(0)]], const device float *in [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    float v = in[gid];
    if (useScale) v *= scaleFactor;
    for (int i = 0; i < extraPasses; ++i) v = v * 0.5 + 1.0;
    out[gid] = v + (is_function_constant_defined(useScale) ? 100.0 : 0.0);
}

constant bool skipBias = !useScale;

kernel void fc_predicated(device float *out [[buffer(0)]], const device float *in [[buffer(1)]],
                          const device float *bias [[buffer(2), function_constant(skipBias)]],
                          uint gid [[thread_position_in_grid]]) {
    float v = in[gid];
    if (skipBias) v += bias[gid];
    out[gid] = useScale ? v * scaleFactor : v;
}
