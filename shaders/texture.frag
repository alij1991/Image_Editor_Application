#version 460 core
#include <flutter/runtime_effect.glsl>

// texture.frag — fine-frequency local-contrast enhancement.
//
// Phase XVI.23: Sibling to clarity.frag. The two share an inline
// 9-tap Gaussian blur but differ in radius and target band:
//   - clarity: r = 1.5 px → midtone-masked unsharp (broad mid-feel)
//   - texture: r = 0.5 px → unmasked unsharp (fine detail)
// "Texture" mirrors Lightroom's slider introduced in 2019: a Sharpen-
// adjacent fine-frequency boost that doesn't clip highlights or
// crush shadows the way Clarity does — and that operates across the
// full luminance range so skin pores, fabric weave and foliage edges
// all benefit from a positive nudge.
//
// Amount scale is halved vs. clarity (0.5 multiplier on the mix
// factor) so a +1 user-slider corresponds to "noticeably crisper"
// rather than the over-bright ringing that an unmasked +1 unsharp
// at clarity's amplitude would produce. Range [-1, 1]; positive
// lifts micro-detail, negative softens (skin, cloth, water).
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount; // -1..+1
out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 px = 1.0 / u_size;

    // 3x3 Gaussian at 0.5 px spacing. A tighter radius than
    // clarity's 1.5 px so the unsharp picks up high-frequency
    // detail instead of broad-midtone bloom. Weight pattern
    //   1 2 1
    //   2 4 2  × 1/16
    //   1 2 1
    // is shared with clarity for code parity.
    float r = 0.5;
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
    // Halved scale vs. clarity (no midtone mask + 0.5 multiplier).
    // The unmasked unsharp is wider in tonal effect than clarity's
    // midtone-only formulation; halving the amplitude keeps the
    // slider feel sane at the slider extremes (+1 / -1).
    vec3 outColor = mix(blurred, sharp.rgb, 1.0 + u_amount * 0.5);
    fragColor = vec4(clamp(outColor, 0.0, 1.0), sharp.a);
}
