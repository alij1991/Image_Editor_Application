#version 460 core
#include <flutter/runtime_effect.glsl>

// chromatic_aberration.frag — RGB channel offset around the center.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount; // 0..1
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 dir = (uv - 0.5) * u_amount * 0.02;
    float r = texture(u_texture, uv + dir).r;
    float g = texture(u_texture, uv).g;
    float b = texture(u_texture, uv - dir).b;
    float a = texture(u_texture, uv).a;
    fragColor = vec4(r, g, b, a);
}
