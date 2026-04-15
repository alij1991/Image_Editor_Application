#version 460 core
#include <flutter/runtime_effect.glsl>

// vibrance.frag — smart saturation: boosts less-saturated colors more.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_vibrance; // -1..+1
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    float maxC = max(src.r, max(src.g, src.b));
    float minC = min(src.r, min(src.g, src.b));
    float sat = maxC - minC;
    // Vibrance boosts low-saturation pixels more, leaves saturated ones alone.
    // Clamp scale to [0, 2] to prevent inversion or extreme overshoot.
    float scale = clamp(1.0 + u_vibrance * 1.5 * (1.0 - sat), 0.0, 2.5);
    float lum = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 outColor = mix(vec3(lum), src.rgb, scale);
    fragColor = vec4(clamp(outColor, 0.0, 1.0), src.a);
}
