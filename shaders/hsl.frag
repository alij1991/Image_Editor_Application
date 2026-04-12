#version 460 core
#include <flutter/runtime_effect.glsl>

// hsl.frag
// 8-band HSL adjustment (Lightroom-style per-hue H / S / L sliders).
// Bands: red, orange, yellow, green, aqua, blue, purple, magenta.
// Each band has a smoothstep weight based on the pixel's hue, and the
// final delta is the weighted sum of per-band adjustments.

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;

// 8 bands x 3 params (hue shift, saturation delta, lightness delta).
// Hue deltas in [-1,1] map to a full hue wheel.
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

vec3 rgbToHsl(vec3 c) {
    float maxC = max(c.r, max(c.g, c.b));
    float minC = min(c.r, min(c.g, c.b));
    float l = (maxC + minC) * 0.5;
    float d = maxC - minC;
    float h = 0.0;
    float s = 0.0;
    if (d > 1e-5) {
        s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC);
        if (maxC == c.r)      h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        else if (maxC == c.g) h = (c.b - c.r) / d + 2.0;
        else                   h = (c.r - c.g) / d + 4.0;
        h /= 6.0;
    }
    return vec3(h, s, l);
}
float hue2rgb(float p, float q, float t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5)       return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}
vec3 hslToRgb(vec3 hsl) {
    float h = hsl.x;
    float s = hsl.y;
    float l = hsl.z;
    if (s < 1e-5) return vec3(l);
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return vec3(hue2rgb(p, q, h + 1.0 / 3.0),
                hue2rgb(p, q, h),
                hue2rgb(p, q, h - 1.0 / 3.0));
}

float bandWeight(float hue, int i) {
    // Circular distance to the band center, with soft falloff.
    float center = kBandCenters[i];
    float dist = abs(hue - center);
    dist = min(dist, 1.0 - dist); // wrap
    // Each band covers ~1/8 of the hue wheel; smoothstep falls to 0 at 1/8.
    return 1.0 - smoothstep(0.0, 1.0 / 8.0, dist);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    vec3 hsl = rgbToHsl(src.rgb);

    float hueShift = 0.0;
    float satAcc = 0.0;
    float lumAcc = 0.0;
    float weightSum = 0.0;
    for (int i = 0; i < 8; i++) {
        float w = bandWeight(hsl.x, i);
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

    hsl.x = fract(hsl.x + hueShift * 0.5);           // half-wheel max shift
    hsl.y = clamp(hsl.y * (1.0 + satAcc), 0.0, 1.0);
    hsl.z = clamp(hsl.z + lumAcc * 0.5, 0.0, 1.0);

    fragColor = vec4(hslToRgb(hsl), src.a);
}
