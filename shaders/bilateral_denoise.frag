#version 460 core
#include <flutter/runtime_effect.glsl>

// bilateral_denoise.frag — edge-preserving blur (small-kernel smart denoise).
// Based on the classic "glslSmartDeNoise" approach by Michele Morrone:
// a Gaussian-weighted bilateral filter where each tap is also weighted by
// the color distance to the center pixel. Small radius (7x7) keeps the
// preview path within the <5 ms budget.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_sigmaSpatial; // spatial Gaussian sigma in pixels
uniform float u_sigmaRange;   // color-distance sigma in linear RGB
uniform float u_radius;       // sampling radius in pixels (kept small)

out vec4 fragColor;

const float TWO_PI = 6.28318530718;
const float INV_SQRT_TAU = 0.39894228;

float gaussian(float x, float sigma) {
    float s2 = sigma * sigma;
    return exp(-(x * x) / (2.0 * s2)) / (sigma * 2.50662827);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 center = texture(u_texture, uv);

    float radius = max(u_radius, 1.0);
    vec2 texel = 1.0 / u_size;

    vec3 sum = vec3(0.0);
    float wsum = 0.0;

    // 7x7 sample window, stride = ceil(radius / 3).
    int step = int(max(1.0, radius / 3.0));
    for (int y = -3; y <= 3; y++) {
        for (int x = -3; x <= 3; x++) {
            vec2 off = vec2(float(x * step), float(y * step)) * texel;
            vec3 c = texture(u_texture, uv + off).rgb;
            float dSpatial = length(vec2(float(x), float(y)) * float(step));
            float dRange = length(c - center.rgb);
            float w = gaussian(dSpatial, u_sigmaSpatial)
                    * gaussian(dRange, u_sigmaRange);
            sum += c * w;
            wsum += w;
        }
    }

    vec3 outColor = wsum > 0.0 ? sum / wsum : center.rgb;
    fragColor = vec4(outColor, center.a);
}
