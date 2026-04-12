#version 460 core
#include <flutter/runtime_effect.glsl>

// grain.frag — simple hash-based procedural grain overlay.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount; // 0..1
uniform float u_size_p; // grain cell size in pixels
uniform float u_seed;
out vec4 fragColor;
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233)) + u_seed) * 43758.5453);
}
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    vec2 cell = floor(FlutterFragCoord().xy / max(u_size_p, 1.0));
    float noise = hash(cell) - 0.5;
    vec3 outColor = src.rgb + vec3(noise) * u_amount * 0.3;
    fragColor = vec4(clamp(outColor, 0.0, 1.0), src.a);
}
