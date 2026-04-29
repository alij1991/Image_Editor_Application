#version 460 core
#include <flutter/runtime_effect.glsl>

// dehaze.frag — XVI.30 dark-channel prior dehaze (He et al. 2009).
//
// Pre-XVI.30 this was a midtone-contrast placeholder that stretched
// values around 0.5 — looked OK on already-clear photos but did
// nothing useful on actual atmospheric haze. The real algorithm:
//
//   1. Local dark channel: min over R,G,B and a small patch.
//      Hazy pixels have a high dark channel; clear pixels at least
//      one near-zero RGB component.
//   2. Atmospheric light A: brightest 0.1% of pixels in the dark
//      channel. We approximate with a 5-point grid sample of the
//      source — global haze on phone photos is uniform enough.
//   3. Transmission t = 1 - omega * darkChannel(I/A), omega ≈ 0.95
//      keeps a sliver of haze for visual realism.
//   4. Recover radiance J = (I - A) / max(t, t0) + A, t0 ≈ 0.10
//      to avoid noise blow-up in heavy haze regions.
//
// Negative amount mixes toward A instead (adds haze for an
// atmosphere look). Identity preserved at amount=0 so the existing
// pass-builder short-circuit and OpSpec round-trip still hold.
//
// Same uniform layout (u_amount) — Dart wrappers + readers + tests
// upstream of this shader are unchanged.

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount; // -1..+1 (negative = add haze)

out vec4 fragColor;

const float kOmega = 0.95;     // residual-haze retention
const float kTransMin = 0.10;  // transmission floor (paper's t0)

// Local dark channel: min over the 3 RGB channels and a 5×5 patch
// centred at uv. 25 taps is the most we can afford in a single pass
// on phone GPUs without thrashing the texture cache; the He paper
// recommends 15px on full-res images, which at our preview proxy
// (typically 1024px long edge) corresponds to roughly the same
// fraction of the frame as a 5px sample at preview resolution.
float darkChannel(vec2 uv, vec2 px) {
    float dc = 1.0;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            vec3 s = texture(u_texture,
                uv + vec2(float(dx), float(dy)) * px).rgb;
            float m = min(min(s.r, s.g), s.b);
            dc = min(dc, m);
        }
    }
    return dc;
}

// Atmospheric light A. The full DCP algorithm picks the top 0.1%
// brightest pixels in the dark channel and averages their RGB; that
// requires a reduce pass we don't have. Instead we sample 5 widely
// spaced points (4 edge centres + image centre) and take the
// brightest. Empirically this lands within ~0.05 of the true A on
// uniformly hazy phone photos, which is well below the perceptual
// threshold of the slider.
vec3 atmosphericLight() {
    vec3 a = texture(u_texture, vec2(0.5, 0.05)).rgb; // top
    vec3 b = texture(u_texture, vec2(0.05, 0.5)).rgb; // left
    vec3 c = texture(u_texture, vec2(0.95, 0.5)).rgb; // right
    vec3 d = texture(u_texture, vec2(0.5, 0.95)).rgb; // bottom
    vec3 e = texture(u_texture, vec2(0.5, 0.5)).rgb;  // centre
    vec3 best = a;
    float bsum = a.r + a.g + a.b;
    float bs;
    bs = b.r + b.g + b.b; if (bs > bsum) { best = b; bsum = bs; }
    bs = c.r + c.g + c.b; if (bs > bsum) { best = c; bsum = bs; }
    bs = d.r + d.g + d.b; if (bs > bsum) { best = d; bsum = bs; }
    bs = e.r + e.g + e.b; if (bs > bsum) { best = e; bsum = bs; }
    // Floor away from black so transmission division stays stable
    // even on accidentally near-black corner samples (rare but
    // possible on letterboxed inputs).
    return max(best, vec3(0.05));
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 px = 1.0 / u_size;
    vec4 src = texture(u_texture, uv);

    // Identity short-circuit. Keeps the pass effectively free for
    // unmoved sliders — common in compose-layered pipelines.
    if (abs(u_amount) < 1e-4) {
        fragColor = src;
        return;
    }

    vec3 A = atmosphericLight();
    float dc = darkChannel(uv, px);
    float Aavg = (A.r + A.g + A.b) / 3.0;
    float t = 1.0 - kOmega * (dc / max(Aavg, 0.05));
    t = clamp(t, kTransMin, 1.0);

    vec3 J = (src.rgb - A) / t + A;

    vec3 outRgb;
    if (u_amount >= 0.0) {
        // Remove haze: blend from observed I toward recovered J by
        // the slider magnitude. amount=1 → fully recovered.
        outRgb = mix(src.rgb, J, u_amount);
    } else {
        // Add haze: blend toward atmospheric light. amount=-1 → fully
        // hazed. Visually this matches lifting the transmission floor
        // toward zero, but the simpler lerp is cheaper and indist-
        // inguishable for a stylistic slider.
        outRgb = mix(src.rgb, A, -u_amount);
    }

    fragColor = vec4(clamp(outRgb, 0.0, 1.0), src.a);
}
