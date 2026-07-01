#include <metal_stdlib>
using namespace metal;

// Copied verbatim from apps/Xios/Sources/Shaders.metal: a textured quad that
// force-opaques the sampled BGRA (X/GTK leave the alpha byte 0 for depth-24).

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut v_main(uint vid [[vertex_id]], constant float4 *v [[buffer(0)]]) {
    VOut o;
    o.pos = float4(v[vid].xy, 0.0, 1.0);
    o.uv  = v[vid].zw;
    return o;
}

fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}
