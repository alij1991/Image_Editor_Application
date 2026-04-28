#version 460 core
#include <flutter/runtime_effect.glsl>

// bilateral_denoise.frag — He et al. 2010's self-guided filter
// (XVI.36 replaced the joint-bilateral body). Same Dart wrapper +
// uniform names so persisted pipelines round-trip; the math is now:
//   meanI  = window mean of input
//   varI   = window variance of input
//   a      = varI / (varI + ε)
//   output = meanI + a * (I - meanI)
// In flat regions varI ≈ 0 → a ≈ 0 → output ≈ meanI (smooth). On
// edges varI is large → a ≈ 1 → output ≈ I (preserved). No halo, no
// staircase, O(window size) per pixel — strictly better than the
// bilateral at the same kernel cost.
//
// Param mapping (kept identical to the bilateral op so old saved
// pipelines render the same uniform layout):
//   u_sigmaSpatial → strength multiplier 0..1 (0 = identity)
//   u_sigmaRange   → ε (edge-preservation knob, smaller = sharper)
//   u_radius       → spatial extent in pixels (window radius)
//
// The op type stays `denoiseBilateral` — the rename to "denoise" is
// a UI-only follow-up; back-compat is more valuable than a typed
// rename here.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_sigmaSpatial; // strength 0..1+ (0 = identity)
uniform float u_sigmaRange;   // ε edge sensitivity
uniform float u_radius;       // window radius in pixels (kept small)

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 center = texture(u_texture, uv);

    // Identity short-circuit — saves the 49 texture taps when the
    // user has the slider at zero. (Bilateral did this implicitly via
    // wsum=0; guided filter has no equivalent guard so we add one.)
    if (u_sigmaSpatial <= 0.001) {
        fragColor = center;
        return;
    }

    float radius = max(u_radius, 1.0);
    vec2 texel = 1.0 / u_size;
    int step = int(max(1.0, radius / 3.0));

    // 7×7 sample window — same shape as the old bilateral so tile
    // memory + sample count stay flat under the swap.
    vec3 sumI = vec3(0.0);
    vec3 sumII = vec3(0.0);
    float n = 0.0;
    for (int y = -3; y <= 3; y++) {
        for (int x = -3; x <= 3; x++) {
            vec2 off = vec2(float(x * step), float(y * step)) * texel;
            vec3 c = texture(u_texture, uv + off).rgb;
            sumI  += c;
            sumII += c * c;
            n     += 1.0;
        }
    }
    vec3 meanI = sumI / n;
    vec3 varI  = sumII / n - meanI * meanI;

    // ε scales quadratically — it lives under sigmaRange (which the
    // user expects to feel like the bilateral's range gaussian).
    // Squaring keeps the slider's mid-point feeling like "moderate
    // edge preservation" while tail values still stay finite.
    float eps = max(u_sigmaRange * u_sigmaRange, 1e-6);
    vec3 a = varI / (varI + eps);

    // sigmaSpatial doubles as the strength of the filter so the
    // bilateral's "Smoothing 0..4" slider keeps the same UX. Clamp
    // to [0, 1] — values past 1 don't add real detail beyond what
    // the guided filter recovers.
    float strength = clamp(u_sigmaSpatial / 4.0, 0.0, 1.0);
    vec3 filtered = meanI + a * (center.rgb - meanI);
    vec3 outColor = mix(center.rgb, filtered, strength);

    fragColor = vec4(outColor, center.a);
}
