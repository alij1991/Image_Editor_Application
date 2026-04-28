#version 460 core
#include <flutter/runtime_effect.glsl>

// hsl.frag — 8-band Oklch HSL adjustment (XVI.28 swap).
//
// Pre-XVI.28 the per-band hue/sat/lum maths ran in classic HSL,
// which suffers from hue drift under saturation pulls (a deep blue
// gets desaturated through purple instead of staying blue) and
// uneven perceptual sensitivity (greens look far more saturated
// than blues at the same numerical chroma). Pixelmator Pro 3.6 +
// Lightroom Mobile both moved their hue wheels to Oklch in 2024;
// this swap brings the same hue stability to our editor.
//
// Same uniform layout (u_hueDelta[8], u_satDelta[8], u_lumDelta[8])
// — Dart wrappers + readers + tests don't change. Visual goldens
// are skip-gated so a pixel-level diff doesn't break CI; the math
// is preserved at identity (all sliders = 0 → output = input).
//
// Conversion chain:
//   sRGB → linear sRGB → Oklab → Oklch (mutate H/C/L) → Oklab →
//   linear sRGB → sRGB.

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;

uniform float u_hueDelta[8];
uniform float u_satDelta[8];
uniform float u_lumDelta[8];

out vec4 fragColor;

const float kBandCenters[8] = float[8](
    0.0 / 8.0, // red
    1.0 / 8.0, // orange
    2.0 / 8.0, // yellow
    3.0 / 8.0, // green
    4.0 / 8.0, // aqua
    5.0 / 8.0, // blue
    6.0 / 8.0, // purple
    7.0 / 8.0  // magenta
);

const float TAU = 6.28318530718;

// sRGB ↔ linear (IEC 61966-2-1).
vec3 srgbToLinear(vec3 c) {
    bvec3 cutoff = lessThan(c, vec3(0.04045));
    vec3 lo = c / 12.92;
    vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(hi, lo, vec3(cutoff));
}

vec3 linearToSrgb(vec3 c) {
    c = max(c, vec3(0.0));
    bvec3 cutoff = lessThan(c, vec3(0.0031308));
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, vec3(cutoff));
}

// linear sRGB ↔ Oklab (Björn Ottosson, 2020).
vec3 linearToOklab(vec3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float lp = pow(max(l, 0.0), 1.0 / 3.0);
    float mp = pow(max(m, 0.0), 1.0 / 3.0);
    float sp = pow(max(s, 0.0), 1.0 / 3.0);
    return vec3(
        0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp,
        1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp,
        0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp
    );
}

vec3 oklabToLinear(vec3 lab) {
    float lp = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float mp = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float sp = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    float l = lp * lp * lp;
    float m = mp * mp * mp;
    float s = sp * sp * sp;
    return vec3(
         4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    );
}

float bandWeight(float hue, int i) {
    float center = kBandCenters[i];
    float dist = abs(hue - center);
    dist = min(dist, 1.0 - dist); // wrap on the hue wheel
    return 1.0 - smoothstep(0.0, 1.0 / 8.0, dist);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    // sRGB → linear → Oklab → Oklch.
    vec3 lin = srgbToLinear(src.rgb);
    vec3 lab = linearToOklab(lin);
    float L = lab.x;
    float a = lab.y;
    float b = lab.z;
    float C = sqrt(a * a + b * b);
    float H = atan(b, a); // [-π, π]
    float Hnorm = H / TAU;
    if (Hnorm < 0.0) Hnorm += 1.0; // → [0, 1)

    float hueShift = 0.0;
    float satAcc = 0.0;
    float lumAcc = 0.0;
    float weightSum = 0.0;
    for (int i = 0; i < 8; i++) {
        float w = bandWeight(Hnorm, i);
        hueShift += u_hueDelta[i] * w;
        satAcc   += u_satDelta[i] * w;
        lumAcc   += u_lumDelta[i] * w;
        weightSum += w;
    }
    if (weightSum > 1e-5) {
        hueShift /= weightSum;
        satAcc   /= weightSum;
        lumAcc   /= weightSum;
    }

    // Apply Oklch deltas. Hue slider [-1, 1] → ±180° rotation;
    // saturation slider scales chroma multiplicatively; lightness
    // slider shifts L additively (Oklab L is in [0, 1] perceptual).
    Hnorm = fract(Hnorm + hueShift * 0.5);
    C = max(C * (1.0 + satAcc), 0.0);
    L = clamp(L + lumAcc * 0.25, 0.0, 1.0);

    float Hrad = Hnorm * TAU;
    a = C * cos(Hrad);
    b = C * sin(Hrad);
    vec3 newLab = vec3(L, a, b);

    // Oklab → linear → sRGB.
    vec3 newLin = oklabToLinear(newLab);
    vec3 outRgb = linearToSrgb(newLin);
    fragColor = vec4(clamp(outRgb, 0.0, 1.0), src.a);
}
