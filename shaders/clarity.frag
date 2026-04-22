#version 460 core
#include <flutter/runtime_effect.glsl>

// clarity.frag — midtone local-contrast boost (unsharp mask on midtones).
//
// Phase XI.0.5: self-contained — the shader computes its own 9-tap
// Gaussian blur inline instead of consuming a pre-blurred sampler.
// Earlier `u_blurred` version was shipped but no pass builder ever
// generated the auxiliary texture, so every preset / Auto-Enhance
// that tagged `clarity` silently rendered no-op. The inline blur
// costs ~9 texture samples per fragment; at preview resolutions
// (≤ 1920 px long edge) this is under 1 ms on mobile Impeller.
//
// Mask weights the boost toward the midtones (luma ≈ 0.5) so
// shadows / highlights keep their tone curve. `clarity` is in
// [-1, 1]; positive crunches midtones, negative softens them.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_clarity; // -1..+1
out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 px = 1.0 / u_size;

    // 3x3 Gaussian (σ ≈ 1) at 1.5 px spacing.  Weights normalised so
    // a flat region returns the same value it sampled at `uv`.
    // Layout:
    //   1 2 1
    //   2 4 2    × 1/16
    //   1 2 1
    float r = 1.5;
    vec3 blurred =
        (texture(u_texture, uv + vec2(-r, -r) * px).rgb * 1.0 +
         texture(u_texture, uv + vec2( 0.0, -r) * px).rgb * 2.0 +
         texture(u_texture, uv + vec2( r, -r) * px).rgb * 1.0 +
         texture(u_texture, uv + vec2(-r,  0.0) * px).rgb * 2.0 +
         texture(u_texture, uv                    ).rgb * 4.0 +
         texture(u_texture, uv + vec2( r,  0.0) * px).rgb * 2.0 +
         texture(u_texture, uv + vec2(-r,  r) * px).rgb * 1.0 +
         texture(u_texture, uv + vec2( 0.0,  r) * px).rgb * 2.0 +
         texture(u_texture, uv + vec2( r,  r) * px).rgb * 1.0) / 16.0;

    vec4 sharp = texture(u_texture, uv);
    float lum = dot(sharp.rgb, vec3(0.2126, 0.7152, 0.0722));
    float midtoneMask = 1.0 - 2.0 * abs(lum - 0.5); // peak at 0.5
    vec3 outColor = mix(blurred, sharp.rgb, 1.0 + u_clarity * midtoneMask);
    fragColor = vec4(clamp(outColor, 0.0, 1.0), sharp.a);
}
