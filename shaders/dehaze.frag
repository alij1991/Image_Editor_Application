#version 460 core
#include <flutter/runtime_effect.glsl>

// dehaze.frag — dark channel prior approximation (Phase 0 passthrough).
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount; // -1..+1 (negative = add haze)
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    // Simple approximation: stretch midtones around 0.5 by u_amount.
    vec3 centered = src.rgb - 0.5;
    vec3 scaled = centered * (1.0 + u_amount * 0.6) + 0.5;
    fragColor = vec4(clamp(scaled, 0.0, 1.0), src.a);
}
