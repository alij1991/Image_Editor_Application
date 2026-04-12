#version 460 core
#include <flutter/runtime_effect.glsl>

// split_toning.frag — tints highlights and shadows independently.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform vec3 u_hiColor;
uniform vec3 u_loColor;
uniform float u_balance; // -1..+1
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    float lum = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));
    float mid = 0.5 + u_balance * 0.5;
    float hiW = smoothstep(mid - 0.25, mid + 0.25, lum);
    float loW = 1.0 - hiW;
    vec3 tinted = src.rgb + (u_hiColor - 0.5) * hiW * 0.4
                           + (u_loColor - 0.5) * loW * 0.4;
    fragColor = vec4(clamp(tinted, 0.0, 1.0), src.a);
}
