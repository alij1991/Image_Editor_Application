#version 460 core
#include <flutter/runtime_effect.glsl>

// sharpen_unsharp.frag — simple 3x3 sharpen kernel (Phase 2 upgrades to
// true unsharp mask with configurable radius + threshold).
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount; // 0..2
uniform float u_radius; // reserved for Phase 2
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 tx = 1.0 / u_size;
    vec4 c = texture(u_texture, uv);
    vec4 n = texture(u_texture, uv + vec2(0.0, -tx.y));
    vec4 s = texture(u_texture, uv + vec2(0.0,  tx.y));
    vec4 e = texture(u_texture, uv + vec2( tx.x, 0.0));
    vec4 w = texture(u_texture, uv + vec2(-tx.x, 0.0));
    vec4 sharp = c * (1.0 + 4.0 * u_amount) - (n + s + e + w) * u_amount;
    fragColor = vec4(clamp(sharp.rgb, 0.0, 1.0), c.a);
}
