#version 460 core
#include <flutter/runtime_effect.glsl>

// curves.frag — master + per-channel tone curves via a 256x4 RGBA LUT.
// Row 0 (y=0.125) is the master curve, rows 1..3 (y=0.375/0.625/0.875) are R/G/B.
// The curve LUT is baked on the Dart side in engine/color/curve_lut_baker.dart
// from Bezier control points, so a single sampler lookup evaluates the curve.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform sampler2D u_curveLut;
uniform float u_enabled; // 1.0 = apply, 0.0 = passthrough

out vec4 fragColor;

float sampleCurve(float v, float row) {
    // LUT is 256 wide, 4 tall. y-center for row i is (i + 0.5)/4.
    return texture(u_curveLut, vec2(clamp(v, 0.0, 1.0), (row + 0.5) / 4.0)).r;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    // Apply master first, then per-channel.
    float rm = sampleCurve(src.r, 0.0);
    float gm = sampleCurve(src.g, 0.0);
    float bm = sampleCurve(src.b, 0.0);

    float r = sampleCurve(rm, 1.0);
    float g = sampleCurve(gm, 2.0);
    float b = sampleCurve(bm, 3.0);

    vec3 outColor = u_enabled > 0.5 ? vec3(r, g, b) : src.rgb;
    fragColor = vec4(outColor, src.a);
}
