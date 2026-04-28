#version 460 core
#include <flutter/runtime_effect.glsl>

// grain.frag — XVI.34
//
// Pre-XVI.34 the grain was a single channel-correlated `fract(sin)`
// hash applied uniformly across the luminance range. Two issues:
//
//   1. fract(sin) is white noise — neighbouring pixels often pick
//      similar values, so the grain looks chunky and "buzzes" under
//      motion. Blue-noise has the same per-pixel variance but with
//      high-frequency dominance, so it integrates cleanly to grey.
//   2. Sampling the same hash for R/G/B means the per-pixel grain is
//      always grey. Real film grain has independent silver halide
//      crystals per emulsion layer, so each channel's noise should be
//      decorrelated.
//
// XVI.34 fixes both:
//
//   - Switch to interleaved gradient noise (Jimenez 2014). Cheap,
//     blue-noise-like spectral properties (used in TLOU/CoD/Frostbite
//     for dithering + TAA jitter). Same instruction count as the old
//     `fract(sin)` hash.
//   - Sample three independent offsets for R/G/B so each channel
//     gets its own grain, matching the per-emulsion-layer behaviour
//     of film stock.
//
// Plus the audit's banded-grain feature:
//
//   - 3 luminance bands (shadow / mid / highlight) each with its own
//     amplitude knob. Default 1.0 across all bands matches the pre-
//     XVI.34 uniform-amplitude behaviour. Pulling `highs` toward 0
//     keeps skies clean while shadows still get film texture (the
//     standard "natural film" recipe).
//   - `amount` stays as the master multiplier — kills all grain at 0.

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_amount;     // 0..1 master strength (identity 0)
uniform float u_size_p;     // grain cell size in pixels
uniform float u_seed;
uniform float u_shadows;    // 0..1 per-band amp (identity 1)
uniform float u_mids;       // 0..1 per-band amp (identity 1)
uniform float u_highs;      // 0..1 per-band amp (identity 1)

out vec4 fragColor;

// Jorge Jimenez 2014: interleaved gradient noise. Approximates blue-
// noise spectrum with a single fract+dot. Domain coords should be in
// pixels (or any equally-spaced grid).
float ign(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    // Cell-quantise the position so cellSize > 1 produces visibly
    // chunky grain (matches the pre-XVI.34 cellSize semantics).
    vec2 cell = floor(FlutterFragCoord().xy / max(u_size_p, 1.0));

    // Three independent noise samples for R/G/B. Offsets are big
    // primes so the IGN sample lattice doesn't repeat across channels
    // for any reasonable image dimension. The per-seed shift lets a
    // future "Refresh grain" UI cycle a fresh look without re-baking
    // the whole pass.
    float nR = ign(cell + vec2(u_seed * 113.0,  0.0)) - 0.5;
    float nG = ign(cell + vec2(u_seed * 113.0, 53.0)) - 0.5;
    float nB = ign(cell + vec2(u_seed * 113.0, 117.0)) - 0.5;

    // 3-band luminance split. Same smoothstep shape as
    // color_grading_3wheel; midW is the residue so all bands sum to 1
    // exactly at any luminance.
    float lum = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));
    float shadowW = 1.0 - smoothstep(0.0, 0.5, lum);
    float highW   = smoothstep(0.5, 1.0, lum);
    float midW    = max(0.0, 1.0 - shadowW - highW);

    // Per-band amplitude weights collapse to "uniform 1.0" when every
    // slider is at identity, matching pre-XVI.34 grain uniformity.
    float bandAmp = shadowW * u_shadows + midW * u_mids + highW * u_highs;

    vec3 noise = vec3(nR, nG, nB) * u_amount * bandAmp * 0.3;
    fragColor = vec4(clamp(src.rgb + noise, 0.0, 1.0), src.a);
}
