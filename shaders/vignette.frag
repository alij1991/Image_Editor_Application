#version 460 core
#include <flutter/runtime_effect.glsl>

// vignette.frag — radial darkening around a center.
//
// Phase XVI.33 — subject-protect option. A second sampler binds to
// the latest bg-removal cutout (or a 1×1 transparent fallback when
// the user hasn't run bg-removal yet). The shader samples `.a` from
// the cutout to recover the subject mask, then mixes the vignetted
// rgb back toward the pre-vignette source for masked pixels. When
// `u_protectStrength == 0` (default) the math collapses to identity
// regardless of which mask is bound, so users who haven't enabled
// the protect flag get exactly the pre-XVI.33 vignette behaviour.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform sampler2D u_subjectMask;
uniform float u_amount;          // -1..+1
uniform float u_feather;         // 0..1
uniform float u_roundness;       // 0..1 (higher = more circular)
uniform vec2 u_center;           // normalized 0..1
uniform float u_protectStrength; // 0..1 (XVI.33)
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
    vec3 vignetted = u_amount >= 0.0 ? darkened : lightened;

    // XVI.33 — subject-protect blend. The bg-removal cutout's alpha
    // channel is the subject mask: alpha=1 inside subject, 0 outside.
    // When protectStrength=0 (default) `protect` is 0 and the mix
    // returns vignetted unchanged.
    float mask = texture(u_subjectMask, uv).a;
    float protect = mask * u_protectStrength;
    vec3 outColor = mix(vignetted, src.rgb, protect);
    fragColor = vec4(outColor, src.a);
}
