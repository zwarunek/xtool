#include <metal_stdlib>
using namespace metal;

typedef struct {
    float2 position;
    float4 color;
    float size;
    float age;
} Particle;

typedef struct {
    float lifetime;
    float4x4 projection;
    float sizeScale;
} ParticleUniforms;

struct ParticleOut {
    float4 position [[position]];
    float size [[point_size]];
    float4 color;
    float life;
};

vertex ParticleOut particle_vertex(uint vid [[vertex_id]], constant Particle *particles [[buffer(0)]],
                                   constant ParticleUniforms &uniforms [[buffer(1)]]) {
    Particle p = particles[vid];
    float life = p.age / uniforms.lifetime;
    ParticleOut out;
    out.position = uniforms.projection * float4(p.position, 0.0, 1.0);
    out.size = p.size * uniforms.sizeScale * (1.0 - smoothstep(0.6, 1.0, life));
    out.color = p.color;
    out.color.rgb = mix(out.color.rgb, float3(1.0), smoothstep(0.7, 0.9, life) * 0.5);
    out.life = life;
    return out;
}

fragment float4 particle_fragment(ParticleOut in [[stage_in]], float2 pc [[point_coord]],
                                  texture2d<half> sprite [[texture(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear);
    half4 s = sprite.sample(linearSampler, pc);
    float a = float(s.a) * (1.0 - smoothstep(0.9, 1.0, in.life));
    return float4(in.color.rgb * a, a);
}
