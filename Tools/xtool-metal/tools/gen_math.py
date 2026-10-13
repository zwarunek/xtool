#!/usr/bin/env python3
"""Generate MSL probe kernels: one per (function, type), to learn which AIR calls Apple's compiler emits."""
import sys

FLOAT_T = ['float', 'float2', 'float3', 'float4', 'half', 'half2', 'half3', 'half4']
INT_T = ['int', 'int2', 'int3', 'int4', 'uint', 'uint2', 'uint3', 'uint4', 'short', 'ushort2', 'char', 'uchar4', 'long', 'ulong2']

# name: (arity, type family) ; arity counts generic-typed args
F1 = 'abs acos acosh asin asinh atan atanh ceil cos cosh cospi exp exp2 exp10 fabs floor fract log log2 log10 rint round rsqrt saturate sign sin sinh sinpi sqrt tan tanh tanpi trunc length normalize'.split()
F2 = 'atan2 copysign fdim fmax fmin fmod max min pow powr step distance dot nextafter'.split()
F3 = 'clamp fma mad mix smoothstep'.split()
FV = 'cross reflect'.split()
I1 = 'abs absdiff_unused clz ctz popcount reverse_bits'.split()
I2 = 'absdiff addsat hadd max min mul_hi rhadd subsat rotate'.split()
I3 = 'clamp madsat madhi_unused'.split()

def kern(name, ty, body, extra=''):
    return f'kernel void p_{name}(device {ty} *o [[buffer(0)]], device const {ty} *a [[buffer(1)]]{extra}, uint i [[thread_position_in_grid]]) {{ {body} }}\n'

def main():
    import os
    d = sys.argv[1]; os.makedirs(d, exist_ok=True)
    out = []
    k = 0
    def add(fn, ty, nargs, ret=None):
        nonlocal k
        args = ', '.join(f'a[i+{j}]' for j in range(nargs))
        r = ret or ty
        if r != ty:
            out.append(f'kernel void p{k}_{fn}_{ty}(device {r} *o [[buffer(0)]], device const {ty} *a [[buffer(1)]], uint i [[thread_position_in_grid]]) {{ o[i] = {fn}({args}); }}\n')
        else:
            out.append(kern(f'{k}_{fn}_{ty}', ty, f'o[i] = {fn}({args});'))
        k += 1
    for ty in FLOAT_T:
        scalar = ty.rstrip('234')
        for fn in F1:
            if fn in ('length',):
                add(fn, ty, 1, scalar); continue
            if fn == 'normalize' and ty in ('float', 'half'):
                continue
            add(fn, ty, 1)
        for fn in F2:
            if fn in ('distance', 'dot'):
                add(fn, ty, 2, scalar); continue
            add(fn, ty, 2)
        for fn in F3:
            add(fn, ty, 3)
        if ty in ('float3', 'half3'):
            for fn in FV:
                add(fn, ty, 2)
    for ty in INT_T:
        for fn in I1:
            if fn.endswith('_unused'):
                continue
            add(fn, ty, 1)
        for fn in I2:
            add(fn, ty, 2)
        for fn in I3:
            if fn.endswith('_unused'):
                continue
            add(fn, ty, 3)
    for src in out:
        name = src.split('kernel void ')[1].split('(')[0]
        open(os.path.join(d, name + '.metal'), 'w').write('#include <metal_stdlib>\nusing namespace metal;\n' + src)

main()
