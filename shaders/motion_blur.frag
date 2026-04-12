#version 460 core
#include <flutter/runtime_effect.glsl>

// motion_blur.frag — directional average along u_direction.
// u_samples is clamped to [1, 32] to keep the preview path under budget.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform vec2 u_direction;   // normalized direction
uniform float u_samples;    // sample count
uniform float u_strength;   // 0..1 — scales the sample spread

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    int samples = int(clamp(u_samples, 1.0, 32.0));
    vec2 step = u_direction * (u_strength * 0.05) / float(samples);
    vec3 acc = vec3(0.0);
    for (int i = 0; i < 32; i++) {
        if (i >= samples) break;
        float t = float(i) - float(samples - 1) * 0.5;
        acc += texture(u_texture, uv + step * t).rgb;
    }
    acc /= float(samples);
    fragColor = vec4(mix(src.rgb, acc, u_strength), src.a);
}
