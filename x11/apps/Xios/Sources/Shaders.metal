#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

// Fullscreen-ish quad from 4 packed float4 verts (pos.xy, uv.zw).
vertex VOut v_main(uint vid [[vertex_id]], constant float4 *v [[buffer(0)]]) {
    VOut o;
    o.pos = float4(v[vid].xy, 0.0, 1.0);
    o.uv  = v[vid].zw;
    return o;
}

fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    // X's framebuffer leaves the high (alpha) byte at 0 for depth-24 visuals; force
    // opaque so the layer doesn't composite the framebuffer as transparent.
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}
