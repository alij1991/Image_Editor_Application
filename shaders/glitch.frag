#version 460 core
#include <flutter/runtime_effect.glsl>

// glitch.frag — row-based glitch effect.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount;
uniform float u_time;
out vec4 fragColor;
float hash(float x) { return fract(sin(x * 12.9898 + u_time) * 43758.5453); }
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    float row = floor(uv.y * 64.0);
    float offset = (hash(row) - 0.5) * u_amount * 0.1;
    vec2 shifted = vec2(uv.x + offset, uv.y);
    fragColor = texture(u_texture, shifted);
}
