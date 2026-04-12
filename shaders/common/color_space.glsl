// color_space.glsl
// Shared helpers for RGB <-> HSL/HSV/LAB conversion and 3D LUT lookup.
// This file is NOT declared in pubspec shaders: — it is #included by the
// .frag files that need it.
//
// Color-space math follows the conventions in the blueprint: Rec.709 luma
// weights (0.2126, 0.7152, 0.0722), sRGB gamma 2.2 for simple cases, and
// full piecewise sRGB for the LAB path.

const vec3 kLumaWeights709 = vec3(0.2126, 0.7152, 0.0722);

float luma709(vec3 c) {
    return dot(c, kLumaWeights709);
}

// sRGB <-> linear (piecewise)
float srgbToLinearComponent(float c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
float linearToSrgbComponent(float c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
vec3 srgbToLinear(vec3 c) {
    return vec3(srgbToLinearComponent(c.r),
                srgbToLinearComponent(c.g),
                srgbToLinearComponent(c.b));
}
vec3 linearToSrgb(vec3 c) {
    return vec3(linearToSrgbComponent(c.r),
                linearToSrgbComponent(c.g),
                linearToSrgbComponent(c.b));
}

// RGB <-> HSL (sRGB input, standard formula).
// hue returned in [0,1].
vec3 rgbToHsl(vec3 c) {
    float maxC = max(c.r, max(c.g, c.b));
    float minC = min(c.r, min(c.g, c.b));
    float l = (maxC + minC) * 0.5;
    float d = maxC - minC;
    float h = 0.0;
    float s = 0.0;
    if (d > 1e-5) {
        s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC);
        if (maxC == c.r) {
            h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        } else if (maxC == c.g) {
            h = (c.b - c.r) / d + 2.0;
        } else {
            h = (c.r - c.g) / d + 4.0;
        }
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

// 3D LUT lookup with 2D-emulated sampler3D.
// The LUT is laid out as N horizontal tiles of NxN each (total width = N*N, height = N).
// N is typically 33 for a 33^3 LUT.
vec3 sampleLut3d(sampler2D lut, vec3 uvw, float tileSize) {
    float slice = uvw.z * (tileSize - 1.0);
    float sliceLo = floor(slice);
    float sliceHi = min(sliceLo + 1.0, tileSize - 1.0);
    float sliceMix = slice - sliceLo;

    // Each slice is a tileSize x tileSize block; slice i lives at x in [i*tileSize, (i+1)*tileSize].
    float invWidth = 1.0 / (tileSize * tileSize);
    float invHeight = 1.0 / tileSize;

    vec2 uvLo;
    uvLo.x = (sliceLo * tileSize + uvw.x * (tileSize - 1.0) + 0.5) * invWidth;
    uvLo.y = (uvw.y * (tileSize - 1.0) + 0.5) * invHeight;

    vec2 uvHi;
    uvHi.x = (sliceHi * tileSize + uvw.x * (tileSize - 1.0) + 0.5) * invWidth;
    uvHi.y = uvLo.y;

    vec3 colLo = texture(lut, uvLo).rgb;
    vec3 colHi = texture(lut, uvHi).rgb;
    return mix(colLo, colHi, sliceMix);
}
