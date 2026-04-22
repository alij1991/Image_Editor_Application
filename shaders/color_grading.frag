#version 460 core
#include <flutter/runtime_effect.glsl>

// color_grading.frag
// Composed-matrix color grading + Kelvin-based white balance.
//
// The matrix is pre-multiplied on the Dart side (matrix_composer.dart) so
// brightness / contrast / saturation / hue / channel-mixer cost zero
// extra math here. Exposure is applied in linear light. Temperature and
// tint are also applied in linear light using a regression-based Kelvin
// → RGB conversion (Tanner Helland's blackbody model) so that hitting
// extreme values can't produce neon shifts on near-grayscale images
// (the old `c.g += tint * 0.15;` bug, where any leftover tint after a
// B&W preset turned the photo bright green).

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;

// Pre-composed 4x4 color matrix (rows are output channel coefficients).
uniform mat4 u_colorMatrix;
uniform vec4 u_colorOffset;

// Non-matrix adjustments.
uniform float u_exposure;    // stops, typical range -4..+4
uniform float u_temperature; // -1..+1, cool..warm
uniform float u_tint;        // -1..+1, green..magenta

out vec4 fragColor;

// --- sRGB <-> linear (piecewise IEC 61966-2-1) ---
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

// Tanner Helland's blackbody → RGB regression. Valid for ~1000K..40000K;
// the slider clamps us to the safe 2000K..12000K window so we never hit
// the degenerate edge cases.
vec3 colorTempToRgb(float kelvin) {
    float t = kelvin / 100.0;
    vec3 rgb = vec3(1.0);
    if (t <= 66.0) {
        rgb.r = 1.0;
        rgb.g = clamp(0.39008157876901960 * log(t) - 0.63184144378862745,
                      0.0, 1.0);
        rgb.b = t <= 19.0
            ? 0.0
            : clamp(0.54320678911019607 * log(t - 10.0) - 1.19625408914,
                    0.0, 1.0);
    } else {
        float u = t - 60.0;
        rgb.r = clamp(1.29293618606274509 * pow(u, -0.1332047592), 0.0, 1.0);
        rgb.g = clamp(1.12989086089529411 * pow(u, -0.0755148492), 0.0, 1.0);
        rgb.b = 1.0;
    }
    return rgb;
}

// Map the [-1, 1] temperature slider onto a 2000..12000 Kelvin range
// with 6500K (D65) as neutral. Slider convention matches Lightroom /
// Photoshop: positive = warm (yellow/orange), negative = cool (blue).
//
// Phase XI.0.6: previous implementation had the sign flipped —
// `kelvin = 6500 + temp * 5500` sent positive values to 12000K (cool)
// instead of 2000K (warm). Every preset that bumped temperature
// positive (Warm Sun, Warm Sunset, Sepia, B&W Gold, Vintage, …)
// produced the opposite of its intent. The subtraction below goes
// the correct direction: +1 → 2000K (warm), -1 → 12000K (cool).
vec3 whiteBalanceMultiplier(float temp) {
    float kelvin = 6500.0 - temp * (temp >= 0.0 ? 4500.0 : 5500.0);
    return colorTempToRgb(kelvin) / colorTempToRgb(6500.0);
}

// Apply white balance (linear-light) and tint (green<->magenta).
vec3 applyWhiteBalance(vec3 lin, float temp, float tint) {
    lin *= whiteBalanceMultiplier(temp);
    // Tint push: positive = magenta (R+B up, G down); negative = green.
    // Strength is conservative (0.18) so even ±1 stays photo-realistic.
    float g = tint * 0.18;
    lin.r *= (1.0 + g * 0.5);
    lin.g *= (1.0 - g);
    lin.b *= (1.0 + g * 0.5);
    return lin;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    // Exposure in linear light (a stop is a doubling of light).
    vec3 lin = srgbToLinear(clamp(src.rgb, 0.0, 1.0))
             * pow(2.0, u_exposure);
    vec3 srgb = linearToSrgb(clamp(lin, 0.0, 16.0));

    // Pre-composed matrix (sat / hue / contrast / brightness / channel mixer).
    vec4 m = u_colorMatrix * vec4(srgb, src.a) + u_colorOffset;
    vec3 graded = clamp(m.rgb, 0.0, 1.0);

    // Temperature + tint in linear light so blown-out / desaturated
    // pixels behave perceptually instead of jumping to neon shifts.
    vec3 mlin = srgbToLinear(graded);
    mlin = applyWhiteBalance(mlin, u_temperature, u_tint);
    vec3 outSrgb = linearToSrgb(clamp(mlin, 0.0, 1.0));

    fragColor = vec4(outSrgb, m.a);
}
