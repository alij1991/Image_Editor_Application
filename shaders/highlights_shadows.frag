#version 460 core
#include <flutter/runtime_effect.glsl>

// highlights_shadows.frag — range-masked lighting adjustment.
// Phase 2 implementation: smoothstep masks on luminance, each of the four
// regions (highlights/shadows/whites/blacks) mapped to non-overlapping
// luminance bands with soft transitions.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_highlights; // -1..+1
uniform float u_shadows;    // -1..+1
uniform float u_whites;     // -1..+1
uniform float u_blacks;     // -1..+1

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    float lum = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));

    // Non-overlapping luminance bands with soft transitions:
    //   blacks:     0.00 – 0.15  (deep shadows)
    //   shadows:    0.10 – 0.50  (lower midtones)
    //   highlights: 0.50 – 0.90  (upper midtones)
    //   whites:     0.85 – 1.00  (specular/near-white)
    float blackMask     = 1.0 - smoothstep(0.05, 0.20, lum);
    float shadowMask    = smoothstep(0.05, 0.20, lum) * (1.0 - smoothstep(0.35, 0.55, lum));
    float highlightMask = smoothstep(0.45, 0.65, lum) * (1.0 - smoothstep(0.80, 0.95, lum));
    float whiteMask     = smoothstep(0.80, 0.95, lum);

    float delta = u_blacks * 0.4 * blackMask
                + u_shadows * 0.5 * shadowMask
                + u_highlights * 0.5 * highlightMask
                + u_whites * 0.4 * whiteMask;

    vec3 outColor = clamp(src.rgb + vec3(delta), 0.0, 1.0);
    fragColor = vec4(outColor, src.a);
}
