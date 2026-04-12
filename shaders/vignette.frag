#version 460 core
#include <flutter/runtime_effect.glsl>

// vignette.frag — radial darkening around a center.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount;    // -1..+1
uniform float u_feather;   // 0..1
uniform float u_roundness; // 0..1 (higher = more circular)
uniform vec2 u_center;     // normalized 0..1
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    vec2 delta = (uv - u_center);
    float aspect = u_size.x / u_size.y;
    delta.x *= mix(1.0, aspect, u_roundness);
    float dist = length(delta) * 1.414; // normalize to corner = 1.0
    float falloff = smoothstep(1.0 - u_feather, 1.0, dist);
    vec3 darkened = src.rgb * (1.0 - falloff * max(u_amount, 0.0));
    vec3 lightened = src.rgb + (1.0 - src.rgb) * falloff * max(-u_amount, 0.0);
    vec3 outColor = u_amount >= 0.0 ? darkened : lightened;
    fragColor = vec4(outColor, src.a);
}
