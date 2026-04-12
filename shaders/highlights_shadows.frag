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

    float shadowMask    = 1.0 - smoothstep(0.0, 0.5, lum);
    float highlightMask = smoothstep(0.5, 1.0, lum);
    float blackMask     = 1.0 - smoothstep(0.0, 0.15, lum);
    float whiteMask     = smoothstep(0.85, 1.0, lum);

    float delta = u_shadows * 0.3 * shadowMask
                + u_highlights * 0.3 * highlightMask
                + u_blacks * 0.2 * blackMask
                + u_whites * 0.2 * whiteMask;

    vec3 outColor = clamp(src.rgb + vec3(delta), 0.0, 1.0);
    fragColor = vec4(outColor, src.a);
}
