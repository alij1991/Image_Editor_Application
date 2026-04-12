#version 460 core
#include <flutter/runtime_effect.glsl>

// radial_blur.frag — radial "zoom" blur from u_center outward.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform vec2 u_center;   // normalized 0..1
uniform float u_strength;// 0..1

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 delta = uv - u_center;
    vec3 acc = vec3(0.0);
    const int samples = 12;
    for (int i = 0; i < samples; i++) {
        float t = 1.0 - (float(i) / float(samples)) * u_strength * 0.25;
        vec2 s = u_center + delta * t;
        acc += texture(u_texture, s).rgb;
    }
    acc /= float(samples);
    vec4 src = texture(u_texture, uv);
    fragColor = vec4(mix(src.rgb, acc, u_strength), src.a);
}
