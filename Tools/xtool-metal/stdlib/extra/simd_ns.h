// simd:: names for headers shared between Swift/Objective-C and Metal (simd/simd.h in Metal mode).
#ifndef __XT_SIMD_NS
#define __XT_SIMD_NS
#include <metal_stdlib>
namespace simd {
using namespace metal;
using ::float2; using ::float3; using ::float4; using ::half2; using ::half3; using ::half4;
using ::int2; using ::int3; using ::int4; using ::uint2; using ::uint3; using ::uint4;
using ::short2; using ::short3; using ::short4; using ::ushort2; using ::ushort3; using ::ushort4;
using ::char2; using ::char3; using ::char4; using ::uchar2; using ::uchar3; using ::uchar4;
using metal::float2x2; using metal::float3x3; using metal::float4x4; using metal::float2x3; using metal::float2x4;
using metal::float3x2; using metal::float3x4; using metal::float4x2; using metal::float4x3;
using metal::half2x2; using metal::half3x3; using metal::half4x4;
}
#endif
