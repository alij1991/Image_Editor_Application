#version 460 core
#include <flutter/runtime_effect.glsl>

// color_grading_3wheel.frag — XVI.27
//
// Lightroom-style three-wheel Color Grading: independent tints for the
// shadows, midtones, and highlights bands plus a Global wheel that sits
// on top of the three. Each wheel encodes hue + saturation as an RGB
// tint stored around 0.5 (so neutral = vec3(0.5)), exactly the same
// convention used by `split_toning.frag`. The new ingredient is the
// per-band weight: smoothstep masks split the input luminance into
// three soft regions, each pulled by its own tint, and the result is
// summed plus the global tint.
//
// Math:
//   lum    = Rec.709 luminance of the input
//   mid    = 0.5 + balance * 0.25   // balance shifts the midpoint
//   shaW   = 1 - smoothstep(0, mid, lum)            // peaks at lum=0
//   highW  = smoothstep(mid, 1, lum)                // peaks at lum=1
//   midW   = max(0, 1 - shaW - highW)               // bell in between
//   tint   = (shadowColor - 0.5) * shaW * 0.6
//          + (midColor    - 0.5) * midW  * 0.6
//          + (highColor   - 0.5) * highW * 0.6
//          + (globalColor - 0.5) * 0.4               // global at half
//   out    = src + tint * blending
//
// The 0.6 / 0.4 amplitudes match split_toning's 0.4 multiplier extended
// to four contributors so a fully-saturated pick on every wheel can't
// blow past +/-1.0 — the global is bounded by 0.4 so its contribution
// alone never dominates. `blending` is the master mix (Lightroom
// labels this "Blending"; effectively 0..1 dry/wet).

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;

uniform vec3 u_shadowColor;  // 0.5,0.5,0.5 = neutral
uniform vec3 u_midColor;
uniform vec3 u_highColor;
uniform vec3 u_globalColor;
uniform float u_balance;     // -1..+1
uniform float u_blending;    // 0..+1

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    float lum = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));
    float mid = clamp(0.5 + u_balance * 0.25, 0.05, 0.95);

    // Soft three-band split. shadowW / highW are mirror smoothsteps
    // anchored at mid; midW is the residue, clamped to be non-negative
    // for the rare case smoothsteps overlap.
    float shadowW = 1.0 - smoothstep(0.0, mid, lum);
    float highW   = smoothstep(mid, 1.0, lum);
    float midW    = max(0.0, 1.0 - shadowW - highW);

    vec3 tint = (u_shadowColor - 0.5) * shadowW * 0.6
              + (u_midColor    - 0.5) * midW    * 0.6
              + (u_highColor   - 0.5) * highW   * 0.6
              + (u_globalColor - 0.5) * 0.4;

    vec3 graded = src.rgb + tint * u_blending;
    fragColor = vec4(clamp(graded, 0.0, 1.0), src.a);
}
