#version 460 core
#include <flutter/runtime_effect.glsl>

// levels_gamma.frag — black point / white point / gamma adjustment.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_black; // 0..1 input black
uniform float u_white; // 0..1 input white
uniform float u_gamma; // 0.1..5
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    float range = max(u_white - u_black, 1e-3);
    vec3 remapped = clamp((src.rgb - vec3(u_black)) / range, 0.0, 1.0);
    vec3 gamma = pow(remapped, vec3(1.0 / u_gamma));
    fragColor = vec4(gamma, src.a);
}
