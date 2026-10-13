#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[stitchable]] half4 chromatic_split(float2 position, SwiftUI::Layer layer, float amount) {
    half4 r = layer.sample(position + float2(amount, 0.0));
    half4 g = layer.sample(position);
    half4 b = layer.sample(position - float2(0.0, amount));
    return half4(r.r, g.g, b.b, g.a);
}

[[stitchable]] float2 ripple_distort(float2 position, float time, float strength) {
    float2 d = position - float2(32.0);
    float r = length(d);
    return position + normalize(d + 1e-4) * sin(r * 0.4 - time) * strength;
}
