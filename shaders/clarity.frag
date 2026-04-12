#version 460 core
#include <flutter/runtime_effect.glsl>

// clarity.frag — midtone unsharp mask. Phase 2 provides pre-blurred sampler.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform sampler2D u_blurred;
uniform float u_clarity; // -1..+1
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 sharp = texture(u_texture, uv);
    vec4 blurred = texture(u_blurred, uv);
    float lum = dot(sharp.rgb, vec3(0.2126, 0.7152, 0.0722));
    float midtoneMask = 1.0 - 2.0 * abs(lum - 0.5); // peak at 0.5
    vec3 outColor = mix(blurred.rgb, sharp.rgb, 1.0 + u_clarity * midtoneMask);
    fragColor = vec4(clamp(outColor, 0.0, 1.0), sharp.a);
}
